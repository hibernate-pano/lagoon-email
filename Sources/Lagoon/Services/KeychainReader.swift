import Foundation
import Security

/// Reads Keychain secrets **without ever hanging**.
///
/// ## The problem this solves
///
/// `SecItemCopyMatching` with `kSecReturnData` on an item whose ACL does
/// not match the calling binary blocks on macOS. The system wants the user
/// to confirm the read; the confirmation is raised by a background
/// `SecurityAgent` that has **no window**; and the calling thread waits in
/// `mach_msg2_trap` for an answer that can never come. This was confirmed
/// on the machine that reported the bug: `sample` showed the app's
/// cooperative thread parked in `SecItemCopyMatching_osx`, while
/// `osascript` reported that `SecurityAgent` had zero windows.
///
/// The app's own `security dump-keychain` showed the cause: the `lagoon.*`
/// items were created on 2026-10-07 by an earlier build. The bundle is
/// ad-hoc signed (`scripts/build-app.sh` says so explicitly), so every
/// rebuild mints a new cdhash, the item's stored ACL no longer matches,
/// and every launch re-asks.
///
/// ## The three answers, and how each is obtained
///
/// | Answer | How it is determined | Can it block? |
/// |---|---|---|
/// | the value | `kSecReturnData` query | **yes** — hence the deadline |
/// | the item exists but is unreadable | attributes-only query, which never prompts | no |
/// | there is no item | either query returns `errSecItemNotFound` | no |
///
/// The attributes-only query is the key to the whole design: it returns
/// the item's metadata *without* decrypting the secret, and macOS does not
/// raise the authorization prompt for it. (Verified on the machine that
/// reported the bug: an attributes-only read of the *blocked*
/// `lagoon.accountId` item returned `errSecSuccess` instantly, while the
/// data read hung.) So existence is cheap and safe, and only the actual
/// data read is raced against a deadline.
///
/// ## Why a deadline and not a cancel
///
/// `SecItemCopyMatching` cannot be interrupted. Once it is in
/// `mach_msg2_trap`, cancelling the surrounding Swift task does not bring
/// it back. So the deadline is implemented by **not waiting** for the
/// read: it runs on a detached thread, and the caller takes whichever
/// finishes first — the read or the clock.
public enum KeychainReader {
    /// How long a read may take before the app treats the Keychain as
    /// blocked.
    ///
    /// Long enough that a slow-but-working Keychain (a busy machine, a
    /// cold login keychain) still succeeds; short enough that the user is
    /// not left staring at a spinner. Five seconds is the middle: the
    /// system prompt, when it *does* appear, appears in well under a
    /// second.
    public static let readTimeout: TimeInterval = 5

    /// Reads a string secret, with a hard deadline.
    ///
    /// Never blocks the caller for longer than `timeout`. The returned
    /// value distinguishes "absent" from "present but unreadable", which
    /// the old `try?` + `nil` API could not.
    public static func readString(
        service: String,
        timeout: TimeInterval = readTimeout
    ) async -> KeychainRead<String> {
        switch await readRaw(service: service, timeout: timeout) {
        case .missing:
            return .missing
        case .failed(let failure):
            return .failed(failure)
        case .found(let data):
            guard let string = String(data: data, encoding: .utf8) else {
                return .failed(.corrupt)
            }
            return .found(string)
        }
    }

    /// Reads the raw bytes for a service, with a hard deadline.
    ///
    /// The read itself runs detached so it cannot block the caller's
    /// thread; the caller waits for whichever finishes first, the read or
    /// the deadline.
    public static func readRaw(
        service: String,
        timeout: TimeInterval = readTimeout
    ) async -> KeychainRead<Data> {
        await readRaw(service: service, location: nil, timeout: timeout)
    }

    /// Reads the raw bytes from **one** location, with the same deadline.
    ///
    /// `location: nil` searches both in the store's own order. The
    /// location-specific form exists for verification: when the migration
    /// asks "did my write to the destination land?", a search would happily
    /// find the *old* copy and call the write verified — and then delete
    /// the very item it had just mistaken for proof.
    static func readRaw(
        service: String,
        location: KeychainLocation?,
        timeout: TimeInterval = readTimeout
    ) async -> KeychainRead<Data> {
        let read = Task.detached(priority: .userInitiated) { () -> KeychainRead<Data> in
            if let location {
                return KeychainStore.readRaw(service: service, location: location)
            }
            return KeychainStore.readRaw(service: service)
        }

        // Race the read against the clock. `Task.sleep` is cancelled by the
        // group when the read wins, so a fast read does not leave a timer
        // running for five seconds.
        let outcome: KeychainRead<Data>? = await withTaskGroup(
            of: KeychainRead<Data>?.self,
            returning: KeychainRead<Data>?.self
        ) { group in
            group.addTask { await read.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let outcome {
            return outcome
        }

        // The read did not come back in time; it is still parked inside the
        // Security framework and will stay there. Do not retry it — a
        // second blocked read would park a second thread forever.
        //
        // The attributes-only probe answers the question that matters: is
        // there an item here at all? If there is, the item is *present but
        // unreadable*, which is the case the user must be told about,
        // because it is not the same as "you have no saved account".
        let exists: Bool
        if let location {
            exists = KeychainStore.itemExists(service: service, location: location)
        } else {
            exists = KeychainStore.itemExists(service: service, location: .dataProtection)
                || KeychainStore.itemExists(service: service, location: .file)
        }
        if exists {
            return .failed(.authorizationRequired)
        }
        return .missing
    }
}
