import Foundation
import Hummingbird
import Logging
import GRDB
import LagoonKit

/// The reminders the user set for themselves.
///
/// - `GET    /api/reminders?accountId=` → the reminders still waiting
/// - `POST   /api/reminders?accountId=` `{remoteId, dueAt, note?}` → set one
/// - `POST   /api/reminders/:id/dismiss?accountId=` → dismiss or restore
/// - `DELETE /api/reminders/:id?accountId=` → remove it outright
///
/// ## Why this file exists
///
/// The AI could say "remind", the row carried a bell, and the copy read
/// "建议提醒" — and nothing was ever stored, nothing was ever scheduled,
/// nothing ever happened. The user was shown a promise the product could
/// not keep.
///
/// **This file cannot touch the mailbox.** A reminder is a note to
/// yourself; it changes no mail, so it needs no undo and no audit row in
/// `ai_actions` — that table is for things the user *did* to their
/// mailbox, and a note is not one of them. The same rule the advice
/// routes obey, for the same reason.
public enum ReminderRoutes {
    public static func register(
        on router: Router<BasicRequestContext>,
        db: LagoonDB,
        logger: Logger
    ) {
        // GET /api/reminders?accountId=<uuid>[&includeDismissed=true]
        // 200 ReminderListResponse | 400 malformed-accountId
        // | 404 unknown-account | 500 internal-error
        router.get("api/reminders") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            // The dismissed ones are hidden by default and shown on
            // request. A dismissal is a "done", and a done thing has no
            // business in the list the user looks at to remember what is
            // still waiting — but it must be findable, because "done" and
            // "mis-clicked" are indistinguishable after the fact.
            let includeDismissed = request.uri.queryParameters["includeDismissed"]
                .map(String.init) == "true"
            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                let rows = includeDismissed
                    ? try await ReminderStore.all(forAccount: accountId, db: db)
                    : try await ReminderStore.pending(forAccount: accountId, db: db)
                return RouteJSON.response(ReminderListResponse(reminders: rows))
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "reminder.list", logger: logger, failure: error
                )
            }
        }

        // POST /api/reminders?accountId=<uuid>
        // 200 Reminder | 400 malformed-* | 404 unknown-message
        router.post("api/reminders") { request, _ -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            struct SetRequest: Decodable {
                let remoteId: String
                /// ISO-8601, because that is what the client's decoder
                /// produces and what every other date on the wire uses.
                let dueAt: Date
                let note: String?
            }
            let body: SetRequest
            do {
                body = try RouteJSON.decoder().decode(
                    SetRequest.self,
                    from: try await RouteParams.collectBody(request)
                )
            } catch {
                return RouteJSON.error(.badRequest, "malformed-body")
            }
            let remoteId = body.remoteId.trimmingCharacters(in: .whitespacesAndNewlines)
            // The remoteId is bound as a SQL parameter, so it cannot inject
            // anything — but a CR or LF in it is still a value the server
            // never produced, and it would end up in a notification's text.
            guard !remoteId.isEmpty,
                  !remoteId.utf8.contains(0x0D),
                  !remoteId.utf8.contains(0x0A),
                  !remoteId.utf8.contains(0x00)
            else {
                return RouteJSON.error(.badRequest, "malformed-remoteId")
            }
            // A reminder in the past is a reminder that can never fire. The
            // user meant "later"; the clock disagrees. Refusing it is better
            // than storing a row that is already overdue on creation.
            guard body.dueAt > Date() else {
                return RouteJSON.error(.badRequest, "reminder-due-in-past")
            }
            let note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                guard try await AccountStore.find(byId: accountId, db: db) != nil else {
                    return RouteJSON.error(.notFound, "unknown-account")
                }
                let reminder = try await ReminderStore.set(
                    accountId: accountId,
                    remoteId: remoteId,
                    dueAt: body.dueAt,
                    note: (note?.isEmpty ?? true) ? nil : note,
                    db: db
                )
                guard let reminder else {
                    // The message is gone — it was deleted, or the id is
                    // wrong. 404, and the name does not say which.
                    return RouteJSON.error(.notFound, "unknown-message")
                }
                return RouteJSON.response(reminder)
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "reminder.set", logger: logger, failure: error
                )
            }
        }

        // POST /api/reminders/:id/dismiss?accountId=
        // 200 Reminder | 400 malformed-* | 404 unknown-reminder
        router.post("api/reminders/:id/dismiss") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let rawId = context.parameters.get("id"),
                  let reminderId = Int64(rawId), reminderId > 0
            else {
                return RouteJSON.error(.badRequest, "malformed-reminderId")
            }
            struct DismissRequest: Decodable {
                let dismissed: Bool?
            }
            var dismissed = true
            do {
                let body = try JSONDecoder().decode(
                    DismissRequest.self,
                    from: try await RouteParams.collectBody(request)
                )
                dismissed = body.dismissed ?? true
            } catch {
                // An empty body means "dismiss", which is the common case.
                // A body that is not JSON at all is the same thing.
                dismissed = true
            }
            do {
                let updated = try await ReminderStore.setDismissed(
                    reminderId: reminderId, accountId: accountId, dismissed: dismissed, db: db
                )
                guard let updated else {
                    return RouteJSON.error(.notFound, "unknown-reminder")
                }
                return RouteJSON.response(updated)
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "reminder.dismiss", logger: logger, failure: error
                )
            }
        }

        // DELETE /api/reminders/:id?accountId=
        // 204 | 400 malformed-* | 404 unknown-reminder
        router.delete("api/reminders/:id") { request, context -> Response in
            guard let accountId = RouteParams.accountId(from: request) else {
                return RouteJSON.error(.badRequest, "malformed-accountId")
            }
            guard let rawId = context.parameters.get("id"),
                  let reminderId = Int64(rawId), reminderId > 0
            else {
                return RouteJSON.error(.badRequest, "malformed-reminderId")
            }
            do {
                try await ReminderStore.delete(
                    reminderId: reminderId, accountId: accountId, db: db
                )
                return Response(status: .noContent)
            } catch {
                return RouteJSON.failure(
                    .internalServerError, "internal-error",
                    label: "reminder.delete", logger: logger, failure: error
                )
            }
        }
    }
}
