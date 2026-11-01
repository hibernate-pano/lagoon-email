/**
 * M1 feature switches, in one place, so nothing is silently on.
 */

/**
 * Dwell-then-mark-read (POST /api/messages/:id/read, record=false).
 *
 * Left OFF for M1. Reason: that endpoint is documented as "-> UID STORE \Seen
 * (best-effort)" (recon/server-contract.md §3.4) — i.e. it writes to the *real*
 * mailbox on the user's IMAP server. M1's promise is read-only ("不改远端邮箱",
 * task-6 约束), and marking mail seen while the user is only looking for a bug
 * is exactly the kind of silent side effect that promise exists to prevent.
 *
 * m1-checklist §2 asks for "停留后 POST /read（record=false 保持 M1 只读）" — the
 * record=false flag keeps the *audit log* clean, not the remote mailbox. So this
 * is a deliberate, documented deviation: flip this to true when the user has
 * agreed that opening a message may mark it read.
 */
export const ENABLE_MARK_READ = false;

/** How long a message must stay open before a read-mark would fire. */
export const MARK_READ_DWELL_MS = 1000;
/**
 * Dev-only capability-gate bypass: ?bypass-caps=1
 *
 * Why it exists: the seeded synthetic accounts declare archiveFolder=false /
 * trashFolder=false, so a compliant UI disables those buttons — which means the
 * *server-side* 409 path can never be exercised from the browser. With the
 * bypass on, the buttons stay enabled and the server's 409 is what the user
 * sees, which is exactly the "nil = allowed, the server decides" rule proved
 * against a real 409.
 *
 * Never read outside dev: main.tsx only passes it through when import.meta.env.DEV.
 */
export const BYPASS_CAPABILITY_GATE =
  import.meta.env.DEV && new URLSearchParams(window.location.search).has("bypass-caps");

/** How long the undo toast stays up before it stops offering ⌘Z. */
export const UNDO_WINDOW_MS = 8000;
