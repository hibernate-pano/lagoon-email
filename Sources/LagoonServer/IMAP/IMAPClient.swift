import Foundation
import Logging

/// One mailbox as `LIST` reports it. Names are opaque server strings (possibly
/// mUTF-7 on some servers): they are echoed back verbatim, never translated.
public struct IMAPMailbox: Equatable, Sendable {
    public var name: String
    public var attributes: [String]

    public init(name: String, attributes: [String]) {
        self.name = name
        self.attributes = attributes
    }
}

/// The state `SELECT` pins down. `uidValidity` identifies the UID space: when
/// it changes, every stored UID is meaningless and the caller must reset.
///
/// RFC 3501 §2.3.1.1 makes a message's identity the triple (mailbox name,
/// UIDVALIDITY, UID): two folders may legitimately report the same
/// UIDVALIDITY while numbering their mail independently, so `mailbox` is part
/// of the identity, not decoration.
public struct IMAPSelected: Equatable, Sendable {
    public var mailbox: String
    public var exists: Int
    public var uidValidity: Int64
    public var uidNext: Int64

    public init(mailbox: String, exists: Int, uidValidity: Int64, uidNext: Int64) {
        self.mailbox = mailbox
        self.exists = exists
        self.uidValidity = uidValidity
        self.uidNext = uidNext
    }
}

/// One folder's counters as the server reports them (diagnostics only).
///
/// `exists` is the message count the *provider* sees; comparing it against
/// the local store separates "the list window is too small" from "the sync
/// never fetched that far back" — two failures with the same on-screen
/// symptom (missing mail) and completely different fixes.
public struct IMAPMailboxStats: Equatable, Sendable {
    public var name: String
    public var attributes: [String]
    public var exists: Int
    public var uidValidity: Int64
    public var uidNext: Int64
    /// Messages whose UID sits below the first-sync backfill window, i.e. the
    /// mail a fresh connect would never fetch. Measured with `UID SEARCH`, so
    /// it costs one command and no header transfer.
    public var olderThanBackfillWindow: Int

    public init(name: String, attributes: [String], exists: Int, uidValidity: Int64, uidNext: Int64) {
        self.name = name
        self.attributes = attributes
        self.exists = exists
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.olderThanBackfillWindow = 0
    }
}

/// A FETCHed header block. `rawHeaders` keys are lowercased and continuation
/// lines are unfolded; values stay RFC 2047-encoded — decoding belongs to the
/// provider, which decides what to do with broken input.
public struct IMAPFetchedHeader: Equatable, Sendable {
    public var uid: Int64
    public var flags: [String]
    public var internalDate: Date?
    public var rawHeaders: [String: String]

    public init(uid: Int64, flags: [String], internalDate: Date?, rawHeaders: [String: String]) {
        self.uid = uid
        self.flags = flags
        self.internalDate = internalDate
        self.rawHeaders = rawHeaders
    }
}

/// Semantic command layer over `IMAPConnection` (spec §3.1): names the commands
/// and parses their responses, so the provider never touches the wire format.
public actor IMAPClient {
    public static let defaultHeaderFields = [
        "FROM", "SUBJECT", "DATE", "MESSAGE-ID", "IN-REPLY-TO", "REFERENCES", "LIST-UNSUBSCRIBE",
    ]
    public static let clientName = "Lagoon"
    public static let clientVersion = "1.0"

    /// The IMAP verb, kept as its own constant: the SQL guardrail flags any
    /// string literal that mixes a SQL keyword with interpolation, and it
    /// cannot tell `SELECT` the IMAP command from `SELECT` the query.
    static let selectVerb = "SELECT"

    private let connection: IMAPConnection
    private let logger: Logger

    /// Populated by the first `capability()`; cleared on login because the
    /// authenticated set is a superset of the anonymous one on most servers
    /// (spec §3.1 step 5). `nil` means "not asked yet".
    private var cachedCapabilities: Set<String>?

    public init(connection: IMAPConnection, logger: Logger) {
        self.connection = connection
        self.logger = logger
    }

    public func connect(host: String, port: Int) async throws {
        try await connection.connect(host: host, port: port)
    }

    /// Capability names, uppercased (they are case-insensitive per RFC 3501).
    public func capability() async throws -> Set<String> {
        if let cachedCapabilities { return cachedCapabilities }
        let responses = try await connection.execute("CAPABILITY")

        var capabilities: Set<String> = []
        var sawCapabilityLine = false
        for response in responses {
            guard case .untagged = response.kind,
                  response.atoms.count >= 2,
                  response.atoms[1].uppercased() == "CAPABILITY" else { continue }
            sawCapabilityLine = true
            capabilities.formUnion(response.atoms.dropFirst(2).map { $0.uppercased() })
        }
        // A tagged OK without any untagged line is not an answer; leave the
        // cache empty so the next call retries instead of trusting "no MOVE".
        if sawCapabilityLine {
            cachedCapabilities = capabilities
        }
        return capabilities
    }

    /// `AUTHENTICATE PLAIN` + SASL-IR, falling back to `LOGIN` (spec §3.1
    /// step 4). Both forms only ever travel inside TLS. The fallback exists
    /// because failing mechanisms are not always distinguishable server-side:
    /// QQ answers with `NO` (or a continuation that our blank response ends),
    /// and one extra round trip is cheaper than a wrong diagnosis.
    public func login(username: String, authCode: String) async throws {
        let quotedUser = try Self.quoted(username)
        let quotedSecret = try Self.quoted(authCode)
        let payload = Data("\0\(username)\0\(authCode)".utf8).base64EncodedString()

        do {
            _ = try await connection.execute("AUTHENTICATE PLAIN \(payload)")
        } catch let error as MailError {
            // An explicit credential rejection is already the server's final
            // verdict. Retrying it over LOGIN would spend a second failed
            // attempt on exactly the rate-limited or locked accounts that
            // must not be hammered — QQ folds "wrong code / account abnormal
            // / service not open / frequency limited / busy" into one message.
            if case .authFailed = error { throw error }
            logger.debug(
                "imap.auth.saslFallback",
                metadata: ["reason": .string(Self.reasonLabel(error))]
            )
            do {
                _ = try await connection.execute("LOGIN \(quotedUser) \(quotedSecret)")
            } catch let error as MailError {
                // A rejected LOGIN is a credential verdict, not a syntax bug:
                // some servers answer a wrong auth code with a bare NO, and
                // spec §3.4 requires that to stop the retry loop
                // (`needsReconnect`) instead of backing off on a protocol error.
                if case .protocolError("tagged NO") = error { throw MailError.authFailed }
                throw error
            }
        } catch {
            logger.debug(
                "imap.auth.saslFallback",
                metadata: ["reason": .string(Self.reasonLabel(error))]
            )
            _ = try await connection.execute("LOGIN \(quotedUser) \(quotedSecret)")
        }
        // Credentials are never logged; only the failure category above.
        cachedCapabilities = nil
    }

    /// RFC 2971 client identity; a no-op when the server has no `ID`.
    public func sendID() async throws {
        guard try await capability().contains("ID") else {
            logger.debug("imap.id.unsupported")
            return
        }
        let command = "ID (\"name\" \"\(Self.clientName)\" \"version\" \"\(Self.clientVersion)\")"
        _ = try await connection.execute(command)
    }

    public func listMailboxes() async throws -> [IMAPMailbox] {
        let responses = try await connection.execute(#"LIST "" "*""#)
        var mailboxes: [IMAPMailbox] = []
        for response in responses {
            guard case .untagged = response.kind,
                  response.atoms.count >= 2,
                  response.atoms[1].uppercased() == "LIST",
                  let name = response.atoms.last,
                  !name.isEmpty else { continue }
            let attributes = (IMAPResponseParser.parenthesized(response.raw) ?? [])
                .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            mailboxes.append(IMAPMailbox(name: name, attributes: attributes))
        }
        return mailboxes
    }

    public func select(_ mailbox: String) async throws -> IMAPSelected {
        let quoted = try Self.quoted(mailbox)
        let responses = try await connection.execute("\(Self.selectVerb) \(quoted)")

        var selected = IMAPSelected(mailbox: mailbox, exists: 0, uidValidity: 0, uidNext: 0)
        for response in responses {
            guard case .untagged = response.kind else { continue }
            if response.atoms.count >= 3,
               response.atoms[2].uppercased() == "EXISTS",
               let exists = Int(response.atoms[1]) {
                selected.exists = exists
            }
            if let value = Self.number(after: "UIDVALIDITY", in: response.raw) {
                selected.uidValidity = value
            }
            if let value = Self.number(after: "UIDNEXT", in: response.raw) {
                selected.uidNext = value
            }
        }
        if selected.uidValidity == 0 {
            // RFC 3501 §2.3.1.1 requires the UIDVALIDITY response code. A
            // server that omits it leaves every cache keyed on it unable to
            // tell one rebuild from the next — worth a line in the log.
            logger.warning("imap.uidValidityMissing", metadata: [
                "mailbox": .string(mailbox),
            ])
        }
        return selected
    }

    /// Headers for every message from `fromUid` to the mailbox end. The fetch
    /// is `BODY.PEEK` on purpose: syncing must never mark mail as read.
    public func fetchHeaders(
        fromUid: Int64,
        fields: [String] = IMAPClient.defaultHeaderFields
    ) async throws -> [IMAPFetchedHeader] {
        let fieldList = fields.joined(separator: " ")
        let responses = try await connection.execute(
            "UID FETCH \(fromUid):* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(fieldList))])"
        )
        return Self.parseHeaders(responses)
    }

    /// Headers for the newest `count` messages, addressed by *sequence number*.
    ///
    /// Sequence numbers are dense (1…EXISTS) while UIDs are not: every expunge,
    /// move and append burns UIDs forever, so on a mailbox that has been
    /// archived from for years the last 500 *UIDs* can hold a couple of dozen
    /// messages. A bounded history window is a statement about how much mail the
    /// user sees, which is a message count — and measuring it in message counts
    /// requires this form rather than `fetchHeaders(fromUid:)`.
    ///
    /// `exists` is the caller's SELECT result: it makes the range well-defined
    /// without a second round trip, and an empty mailbox answers empty instead
    /// of issuing `FETCH 1:*` over nothing.
    public func fetchNewestHeaders(
        count: Int,
        exists: Int,
        fields: [String] = IMAPClient.defaultHeaderFields
    ) async throws -> [IMAPFetchedHeader] {
        guard exists > 0, count > 0 else { return [] }
        let first = max(1, Int64(exists) - Int64(count) + 1)
        let fieldList = fields.joined(separator: " ")
        let responses = try await connection.execute(
            "FETCH \(first):* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(fieldList))])"
        )
        return Self.parseHeaders(responses)
    }

    /// The same header block for one known UID. The store protects every
    /// column a re-fetch could carry except `is_read` (monotonic OR), so this
    /// single-UID form is for callers that need one message's headers, not for
    /// bulk work — `fetchHeaders(uids:)` is that.
    public func fetchHeader(
        uid: Int64,
        fields: [String] = IMAPClient.defaultHeaderFields
    ) async throws -> [IMAPFetchedHeader] {
        let fieldList = fields.joined(separator: " ")
        let responses = try await connection.execute(
            "UID FETCH \(uid) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(fieldList))])"
        )
        return Self.parseHeaders(responses)
    }

    /// The same header block for a known set of UIDs, in commands of at most
    /// `uidsPerCommand`. The session is strictly serial and one round trip is
    /// paid per command, so a bulk read (a batch of read-state flips) must not
    /// ask for one message at a time.
    public func fetchHeaders(
        uids: [Int64],
        fields: [String] = IMAPClient.defaultHeaderFields
    ) async throws -> [IMAPFetchedHeader] {
        let fieldList = fields.joined(separator: " ")
        var headers: [IMAPFetchedHeader] = []
        for chunk in uids.chunked(into: Self.uidsPerCommand) {
            let set = chunk.map(String.init).joined(separator: ",")
            let responses = try await connection.execute(
                "UID FETCH \(set) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(fieldList))])"
            )
            headers.append(contentsOf: Self.parseHeaders(responses))
        }
        return headers
    }

    /// Flag rescan over a bounded UID window (spec §3.2 step 3) — how the
    /// read/unread state of already-known mail is refreshed.
    public func fetchFlags(fromUid: Int64, toUid: Int64) async throws -> [(uid: Int64, flags: [String])] {
        let responses = try await connection.execute("UID FETCH \(fromUid):\(toUid) (UID FLAGS)")

        var result: [(uid: Int64, flags: [String])] = []
        for response in responses {
            guard case .untagged = response.kind,
                  let items = IMAPResponseParser.parenthesized(response.raw),
                  let uid = Self.numberValue(after: "UID", in: items) else { continue }
            result.append((uid: uid, flags: Self.flagList(in: items)))
        }
        return result
    }

    /// Finds one message by its RFC 5322 `Message-ID`. Archive folders assign
    /// their own UIDs on many servers, so this is the stable identity used to
    /// reverse an archive move.
    public func searchUID(messageID: String) async throws -> Int64? {
        let quoted = try Self.quoted(messageID)
        let responses = try await connection.execute("UID SEARCH HEADER Message-ID \(quoted)")
        for response in responses {
            guard case .untagged = response.kind,
                  response.atoms.count >= 3,
                  response.atoms[0] == "*",
                  response.atoms[1].uppercased() == "SEARCH"
            else { continue }
            return response.atoms.dropFirst(2).compactMap(Int64.init).max()
        }
        return nil
    }

    /// Every UID currently present in the selected mailbox. Used to reconcile
    /// messages another client moved or deleted out of INBOX.
    public func allUIDs() async throws -> Set<Int64> {
        let responses = try await connection.execute("UID SEARCH ALL")
        for response in responses {
            guard case .untagged = response.kind,
                  response.atoms.count >= 2,
                  response.atoms[0] == "*",
                  response.atoms[1].uppercased() == "SEARCH"
            else { continue }
            return Set(response.atoms.dropFirst(2).compactMap(Int64.init))
        }
        return []
    }

    /// How many bytes of a message the list-preview fetch asks for. This is a
    /// *byte* count and has nothing to do with the round-trip count, which is
    /// `ceil(window / uidsPerCommand)` — see `uidsPerCommand`.
    ///
    /// 32768 is deliberately large. `BODY.PEEK[]<0.N>` starts at byte 0, the
    /// RFC 2822 header block, and a real newsletter's `Received` / `DKIM` /
    /// `ARC` headers alone can run to several KB. A window that ends inside
    /// those headers leaves `splitHeadAndBody` without its blank separator, so
    /// `plainText` returns "" and the list shows no preview: measured against
    /// the same 189-message mailbox, 256 B produced previews for 13/189
    /// messages and 4096 B for 67/189, while 32768 B reached 178/189 (94%)
    /// with zero raw-base64 leaks and zero two-character snippets — both of
    /// those were just artifacts of the window clipping the top-level
    /// `content-type` header, not independent decoding bugs.
    ///
    /// The price is at most ~32 KB more per message — a one-off ~16 MB while
    /// backfilling 500 messages. That is bytes on one already-open connection,
    /// not extra round trips: one command answers for up to
    /// `uidsPerCommand` messages, and the literal cap in `IMAPConnection`
    /// applies per response, so a batched FETCH is still bounded at 32 KB per
    /// message rather than per command.
    ///
    /// A cheaper fetch would be a small header slice plus the body:
    /// `UID FETCH uid (UID BODY.PEEK[HEADER.FIELDS (CONTENT-TYPE
    /// CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.N>)`. It cannot be used
    /// today because `IMAPConnection.readResponse` appends every `{N}` literal
    /// in a FETCH response into a single `Data`, so the header and body would
    /// be concatenated. Fix that framing first; until then keep
    /// `BODY.PEEK[]<0.N>`.
    public static let snippetOctets = 32768
    /// UIDs per batched preview FETCH. The strictly serial session pays one
    /// round trip per command, so a 500-message backfill is 5 commands here
    /// (not one), against 500 for a per-message fetch. The line stays a few
    /// KB; a server that refuses an over-long line costs one skipped chunk.
    static let uidsPerCommand = 100

    /// Text-prefix bytes for the given UIDs, keyed by UID: the first `octets`
    /// bytes of each message — headers included so the MIME decoder can tell
    /// what the body is — still transfer-encoded.
    ///
    /// One command per ≤`uidsPerCommand` UIDs instead of one command per
    /// message: on the strictly serial session a backfill of N messages would
    /// otherwise pay N round trips just for previews. The prefix carries the
    /// RFC 822 headers on purpose — the snippet extractor needs the MIME
    /// metadata to decode transfer-encoded bodies.
    public func fetchTextSnippets(
        uids: [Int64],
        octets: Int = IMAPClient.snippetOctets
    ) async throws -> [Int64: Data] {
        var snippets: [Int64: Data] = [:]
        for chunk in uids.chunked(into: Self.uidsPerCommand) {
            let set = chunk.map(String.init).joined(separator: ",")
            do {
                let responses = try await connection.execute(
                    "UID FETCH \(set) (UID BODY.PEEK[]<0.\(octets)>)"
                )
                for response in responses {
                    guard case .untagged = response.kind,
                          let literal = response.literal,
                          let items = IMAPResponseParser.parenthesized(response.raw),
                          let fetchedUid = Self.numberValue(after: "UID", in: items) else { continue }
                    snippets[fetchedUid] = literal
                }
            } catch where Self.isMessageVerdict(error) {
                // A refused chunk costs its own previews, not the ones already
                // collected: the cursor is about to move past these messages,
                // so dropping the whole window here would blank every preview
                // in it for good. The session is still aligned (a tagged
                // completion terminates the command's responses), so the next
                // chunk may go out. A transport failure is deliberately not
                // caught here — it travels on and tears the session down.
                logger.debug("imap.snippetChunkSkipped", metadata: [
                    "label": .string((error as? MailError)?.logLabel ?? "\(type(of: error))"),
                    "uids": .string("\(chunk.count)"),
                ])
            }
        }
        return snippets
    }

    /// Full RFC 822 bytes. An empty result means the UID is gone from the
    /// server (expunged): the caller maps that to a 410 (spec §3.7).
    public func fetchFullBody(uid: Int64) async throws -> Data {
        let responses = try await connection.execute("UID FETCH \(uid) (BODY.PEEK[])")
        guard let literal = responses.compactMap(\.literal).first, !literal.isEmpty else {
            throw MailError.messageGone
        }
        return literal
    }

    public func store(uid: Int64, add: [String] = [], remove: [String] = []) async throws {
        if !add.isEmpty {
            _ = try await connection.execute("UID STORE \(uid) +FLAGS (\(add.joined(separator: " ")))")
        }
        if !remove.isEmpty {
            _ = try await connection.execute("UID STORE \(uid) -FLAGS (\(remove.joined(separator: " ")))")
        }
    }

    /// Requires the server-advertised MOVE capability; the caller falls back to
    /// `copy` + `store` + EXPUNGE when this throws (spec §4.3).
    public func move(uid: Int64, to mailbox: String) async throws {
        guard try await capability().contains("MOVE") else {
            throw MailError.protocolError("MOVE not supported")
        }
        let quoted = try Self.quoted(mailbox)
        _ = try await connection.execute("UID MOVE \(uid) \(quoted)")
    }

    public func copy(uid: Int64, to mailbox: String) async throws {
        let quoted = try Self.quoted(mailbox)
        _ = try await connection.execute("UID COPY \(uid) \(quoted)")
    }

    /// Removes every `\Deleted`-flagged message from the selected mailbox —
    /// the last step of the no-MOVE archiving fallback (spec §4.3).
    ///
    /// ## Do not use this to delete a specific message
    ///
    /// Plain `EXPUNGE` is folder-wide: it removes everything the *server*
    /// considers pending deletion, including messages another client flagged.
    /// For "delete exactly this one" use `uidExpunge(uid:)` — see
    /// `IMAPProvider.permanentlyDelete`, which refuses to run without UIDPLUS
    /// for this reason.
    public func expunge() async throws {
        _ = try await connection.execute("EXPUNGE")
    }

    /// Removes exactly one message (RFC 4315, UIDPLUS).
    ///
    /// The message must already carry `\Deleted`; this call is what makes the
    /// removal real.
    public func uidExpunge(uid: Int64) async throws {
        _ = try await connection.execute("UID EXPUNGE \(uid)")
    }

    /// Removes a set of messages in one round trip (RFC 4315 sequence form).
    public func uidExpunge(uids: [Int64]) async throws {
        guard !uids.isEmpty else { return }
        let list = uids.map(String.init).joined(separator: ",")
        _ = try await connection.execute("UID EXPUNGE \(list)")
    }

    public func createMailbox(_ name: String) async throws {
        let quoted = try Self.quoted(name)
        _ = try await connection.execute("CREATE \(quoted)")
    }

    public func append(mailbox: String, message: Data) async throws {
        try await connection.append(mailbox: try Self.quoted(mailbox), message: message)
    }

    public func idle(waitUpTo: Duration) async throws -> [IMAPResponse] {
        try await connection.idle(waitUpTo: waitUpTo)
    }

    /// LOGOUT then close. A server that hangs up mid-LOGOUT has still ended the
    /// session, so the error is not surfaced (spec §3.4).
    public func logout() async {
        _ = try? await connection.execute("LOGOUT")
        cachedCapabilities = nil
        await connection.close()
    }

    /// Close without the LOGOUT courtesy round trip. Used when the session is
    /// already presumed dead: `execute` would otherwise block for the full
    /// read timeout waiting for a reply that is never coming, and every
    /// abandoned session would hold its socket — and the transport's read pump,
    /// which retains the transport — for that whole window.
    public func disconnect() async {
        cachedCapabilities = nil
        await connection.close()
    }

    // MARK: - Wire helpers

    /// Whether `error` is the server's verdict about the command (or about the
    /// mail it addressed) rather than about the socket. RFC 3501 §7.1 puts
    /// every untagged response of a command *before* that command's tagged
    /// completion, so a tagged NO/BAD consumes the whole response set: nothing
    /// is left on the wire and the next command still sees its own tag. A
    /// transport failure is the opposite — the socket is gone, and the caller
    /// must stop issuing commands on it.
    static func isMessageVerdict(_ error: Error) -> Bool {
        guard let mail = error as? MailError else { return false }
        switch mail {
        case .protocolError, .messageGone, .archiveUnavailable, .trashUnavailable,
            .sentUnavailable:
            // A verdict about the *message or folder*, not the connection, so
            // the caller stops rather than retrying. `sentUnavailable` belongs
            // here for the same reason as `trashUnavailable`: the account has no
            // such folder, and retrying will not conjure one.
            return true
        case .authFailed, .unreachable, .notConfigured:
            return false
        }
    }

    /// RFC 3501 quoted-string. Control characters are refused rather than
    /// escaped: a value that can end the line can also inject a command.
    static func quoted(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw MailError.protocolError("control character in argument")
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// First integer following `keyword` in a raw line, e.g. `UIDNEXT` in
    /// `* OK [UIDNEXT 100] Predicted next UID`.
    static func number(after keyword: String, in raw: String) -> Int64? {
        guard let range = raw.range(of: keyword, options: .caseInsensitive) else { return nil }
        var index = range.upperBound
        while index < raw.endIndex, raw[index] == " " {
            index = raw.index(after: index)
        }
        var digits = ""
        while index < raw.endIndex, raw[index].isASCII, raw[index].isNumber {
            digits.append(raw[index])
            index = raw.index(after: index)
        }
        return digits.isEmpty ? nil : Int64(digits)
    }

    /// Integer in the atom following `keyword` within one FETCH item list.
    static func numberValue(after keyword: String, in atoms: [String]) -> Int64? {
        guard let index = atoms.firstIndex(where: { $0.uppercased() == keyword.uppercased() }),
              index + 1 < atoms.count else { return nil }
        return Int64(atoms[index + 1])
    }

    static func flagList(in atoms: [String]) -> [String] {
        guard let index = atoms.firstIndex(where: { $0.uppercased() == "FLAGS" }),
              index + 1 < atoms.count else { return [] }
        return flagList(atoms[index + 1])
    }

    static func flagList(_ atom: String) -> [String] {
        var value = atom
        if value.hasPrefix("(") { value.removeFirst() }
        if value.hasSuffix(")") { value.removeLast() }
        return value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func internalDate(in atoms: [String]) -> Date? {
        guard let index = atoms.firstIndex(where: { $0.uppercased() == "INTERNALDATE" }),
              index + 1 < atoms.count else { return nil }
        return parseInternalDate(atoms[index + 1])
    }

    /// RFC 3501 date-time (`11-Sep-2026 10:00:00 +0800`) → absolute time.
    /// Parsed by hand: `DateFormatter` is not `Sendable`, and the format is
    /// fixed-width enough that components are exact and allocation-free.
    static func parseInternalDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 3 else { return nil }
        let dateParts = parts[0].split(separator: "-").map(String.init)
        let timeParts = parts[1].split(separator: ":").map(String.init)
        guard dateParts.count == 3, timeParts.count == 3,
              let day = Int(dateParts[0]),
              let month = monthNumber(dateParts[1]),
              let year = Int(dateParts[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              let second = Int(timeParts[2]),
              let offset = utcOffsetSeconds(parts[2]) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let local = calendar.date(from: components) else { return nil }
        // The stamp is local time at `offset`; UTC is that minus the offset.
        return local.addingTimeInterval(-Double(offset))
    }

    static func monthNumber(_ text: String) -> Int? {
        ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
            .firstIndex(of: text.uppercased())
            .map { $0 + 1 }
    }

    /// `+0800` / `-0500` → seconds east of UTC.
    static func utcOffsetSeconds(_ text: String) -> Int? {
        guard text.count == 5 else { return nil }
        let sign: Int
        switch text.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let digits = text.dropFirst()
        guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else {
            return nil
        }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// FETCH responses → header blocks. One parser serves the range fetch and
    /// the single-UID refresh so both interpret the wire form identically.
    static func parseHeaders(_ responses: [IMAPResponse]) -> [IMAPFetchedHeader] {
        var headers: [IMAPFetchedHeader] = []
        for response in responses {
            guard case .untagged = response.kind,
                  let literal = response.literal,
                  let items = IMAPResponseParser.parenthesized(response.raw),
                  let uid = Self.numberValue(after: "UID", in: items) else { continue }
            headers.append(
                IMAPFetchedHeader(
                    uid: uid,
                    flags: Self.flagList(in: items),
                    internalDate: Self.internalDate(in: items),
                    rawHeaders: Self.headerBlock(literal)
                )
            )
        }
        return headers
    }

    /// Raw header block → lowercase name → value, with continuation lines
    /// unfolded. RFC 2047 decoding is deliberately not done here.
    static func headerBlock(_ data: Data) -> [String: String] {
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        func flush() {
            guard let name = currentName else { return }
            headers[name] = currentValue.trimmingCharacters(in: .whitespaces)
            currentName = nil
            currentValue = ""
        }

        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if currentName != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            currentName = name
            currentValue = String(line[line.index(after: colon)...])
        }
        flush()
        return headers
    }

    /// Log-safe failure category — never the command text, which for LOGIN and
    /// AUTHENTICATE carries credentials.
    private static func reasonLabel(_ error: Error) -> String {
        (error as? MailError)?.logLabel ?? "transport"
    }
}

/// Fixed-size chunks, last one possibly smaller.
extension Sequence {
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0, "chunk size must be positive")
        var chunks: [[Element]] = []
        var current: [Element] = []
        for element in self {
            current.append(element)
            if current.count == size {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
