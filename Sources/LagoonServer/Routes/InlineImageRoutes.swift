import Foundation
import Logging
import Hummingbird
import LagoonKit

/// `GET /api/messages/{remoteId}/inline-images?accountId=<uuid>` — the
/// inline (`cid:`) image bytes of one message, in one response.
///
/// ## Why this route exists
///
/// A mail with inline images used to cost the client **N+1 round trips**:
/// one for the body, then one per image, because the body response carried
/// only attachment *metadata* and the bytes lived behind a per-attachment
/// endpoint.
///
/// The server's own cost was worse than the client's. The per-attachment
/// endpoint re-fetched the **entire message** over IMAP and re-parsed it for
/// every single part — so a mail with 20 inline images cost 20 full-message
/// IMAP fetches, each one re-decoding a 5 MB body. That is the shape that
/// made opening a marketing mail slow, and it was invisible from the client
/// side because the client only ever saw "20 requests went out".
///
/// This route reads the message **once** and hands back every inline image
/// in a single response: the client asks once instead of N times, and the
/// server parses once instead of N times.
///
/// ## Why a separate route and not extra fields on the body response
///
/// The body response is a **cacheable** document: it is what
/// `message_bodies` stores, and it is what the AI summarizer, the draft
/// generator and the unsubscribe scanner all read. Inlining image bytes
/// into it would mean every one of those consumers carried megabytes of
/// base64 they do not want, and the stored body would grow by the size of
/// the images on every message.
///
/// A separate route keeps the body response exactly as small as it is today
/// and puts the images where only the HTML renderer needs them. The client
/// calls it **in parallel with** the body fetch, so the two overlap and the
/// user waits for one round trip, not two.
///
/// ## The contract
///
/// The response is `{"images": {"<content-id>": "<base64>"}}`. Keys are
/// Content-IDs **without** angle brackets and lower-cased, because that is
/// the shape the `cid:` reference in the HTML body uses and the client
/// compares case-insensitively.
///
/// Images are capped (both in count and in total bytes) so a hostile
/// message cannot make the server build an unbounded response.
public enum InlineImageRoutes {
    /// Maximum number of inline images returned in one response.
    public static let maxImages = 40
    /// Maximum total decoded bytes across all returned images.
    public static let maxTotalBytes = 8 * 1024 * 1024   // 8 MB

    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger,
        makeProvider: MailProviderFactory.Builder? = nil
    ) {
        let makeProvider = makeProvider
            ?? MailProviderFactory.factory(db: db, logger: logger).builder

        // GET /api/messages/{remoteId}/inline-images?accountId=<uuid>
        // 200 InlineImagesResponse | 400 malformed | 404 unknown | 410 gone
        // | 401 provider-auth-failed | 502 provider-unreachable
        router.get("api/messages/:remoteId/inline-images") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let remoteId = RouteParams.remoteId(from: context) else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            let account: Account
            do {
                guard let found = try await AccountStore.find(byId: accountId, db: db) else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                account = found
            } catch {
                logger.error("inline-images.accountLookupFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.internalServerError, "internal-error")
            }
            guard let provider = makeProvider(account) else {
                return RouteJSON.error(.serviceUnavailable, "provider-not-configured")
            }
            do {
                let images = try await Self.fetchInlineImages(
                    account: account,
                    remoteId: remoteId,
                    provider: provider,
                    logger: logger
                )
                return RouteJSON.response(InlineImagesResponse(images: images))
            } catch let error as MailError {
                return MessageRoutes.providerError(error, logger: logger, remoteId: remoteId)
            } catch {
                logger.error("inline-images.fetchFailed", metadata: [
                    "accountId": .string(accountId.uuidString),
                    "remoteId": .string(remoteId),
                    "err": .string("\(error)"),
                ])
                return RouteJSON.error(.badGateway, "provider-unreachable")
            }
        }
    }

    /// Read the message once and pull out its inline images.
    ///
    /// The whole message is fetched and parsed a single time, which is the
    /// entire point: the old per-attachment route re-fetched and re-parsed
    /// the *entire* message for every single part.
    static func fetchInlineImages(
        account: Account,
        remoteId: String,
        provider: any MailProvider,
        logger: Logger
    ) async throws -> [String: Data] {
        let raw = try await provider.fetchRawMessage(remoteId: remoteId)
        let parsed = MIMEParser.parse(message: raw, decodeAttachmentBytes: true)

        var images: [String: Data] = [:]
        var totalBytes = 0
        for attachment in parsed.attachments {
            // Only inline *images* are inlined. An inline PDF or an inline
            // `message/rfc822` forward is not something the HTML renderer
            // will ever ask for, and shipping its bytes here would be
            // payload nobody wanted.
            guard attachment.disposition == .inline,
                  attachment.mimeType.hasPrefix("image/")
            else { continue }
            guard let contentId = attachment.contentId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !contentId.isEmpty
            else { continue }
            // An image with no bytes is not a broken response — it is an
            // image the server could not decode. Skipping it leaves the
            // client's `cid:` reference unresolved, which the renderer
            // already handles (the image simply does not appear).
            guard !attachment.data.isEmpty else { continue }
            guard images.count < Self.maxImages else {
                logger.info("inline-images.capped", metadata: [
                    "remoteId": .string(remoteId),
                    "reason": .string("too-many-images"),
                ])
                break
            }
            guard totalBytes + attachment.data.count <= Self.maxTotalBytes else {
                logger.info("inline-images.capped", metadata: [
                    "remoteId": .string(remoteId),
                    "reason": .string("total-bytes"),
                ])
                break
            }
            totalBytes += attachment.data.count
            // Lower-cased key: the `cid:` reference in the HTML is compared
            // case-insensitively by the renderer, and Content-IDs are
            // case-insensitive in practice but not consistently cased.
            images[contentId.lowercased()] = attachment.data
        }
        return images
    }
}
