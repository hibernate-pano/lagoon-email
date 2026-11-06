/**
 * The composer: reply, new mail, forward.
 *
 * One panel for all three, because they differ only in what is prefilled and
 * in which route the body goes to. The rules that matter:
 *
 *   - **The user always sees what will be sent.** Recipients are one text
 *     field; the server splits them (it understands `"Zhang, Wei" <a@b>`), so
 *     this file never guesses where an address ends.
 *   - **One requestId, one delivery.** The id is minted per attempt and is
 *     only reused when the previous attempt's outcome is unknown - see
 *     core/send.ts, which owns that rule and its tests.
 *   - **A failure never eats the draft.** The text stays in the fields, so
 *     fixing a recipient and sending again is one click, not retyping.
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  base64ByteLength,
  bytesToBase64,
  draftFor,
  fingerprintOf,
  hasDraftChanges,
  MAX_ATTACHMENT_BYTES,
  MAX_TOTAL_ATTACHMENT_BYTES,
  newRequestId,
  requestIdFor,
  sendFailureTitle,
  sendMail,
  validateForm,
  type SendAttachment,
  type SendAttempt,
  type SendForm,
  type SendMode,
  type SendOriginal,
} from "../core/send";
import { Banner } from "../ui/atoms";
import { ConfirmDialog } from "../ui/ConfirmDialog";
import { t } from "../l10n/zh";

export interface ComposerProps {
  mode: SendMode;
  accountId: string;
  /** The message being replied to or forwarded. */
  original?: SendOriginal;
  onClose: () => void;
  onSent: (info: { providerMessageId?: string }) => void;
}

type Phase =
  | { kind: "idle" }
  | { kind: "sending" }
  | { kind: "refused"; title: string; detail: string }
  | { kind: "unknown"; detail: string }
  | { kind: "inflight"; detail: string };

function titleOf(mode: SendMode): string {
  if (mode === "reply") return t.compose.replyTitle;
  if (mode === "forward") return t.compose.forwardTitle;
  return t.compose.title;
}

export function Composer(props: ComposerProps): ReactNode {
  const { mode, original } = props;
  const [form, setForm] = useState<SendForm>(() => draftFor(mode, original));
  /** What the composer opened with, so "did you write anything" has an answer. */
  const initial = useMemo(() => draftFor(mode, original), [mode, original]);
  /** The close confirmation is local: it is about this sheet, not the window. */
  const [confirmClose, setConfirmClose] = useState(false);
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const [attempt, setAttempt] = useState<SendAttempt | null>(null);
  /**
   * Whether the Cc/Bcc fields are shown.
   *
   * It used to be derived from `form.cc !== "" || form.bcc !== ""`, which no
   * control could ever set: the fields were gated on having been filled in.
   * The user opens them; an already-filled draft starts open.
   */
  const [showCc, setShowCc] = useState(
    () => initial.cc.trim() !== "" || initial.bcc.trim() !== "",
  );
  const [fieldError, setFieldError] = useState<{ field: string; reason: string } | null>(null);
  const [attachmentError, setAttachmentError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);
  const toRef = useRef<HTMLInputElement | null>(null);
  const bodyRef = useRef<HTMLTextAreaElement | null>(null);

  const sending = phase.kind === "sending";

  // Focus the first field that matters: the recipient for a new mail, the body
  // for a reply (the recipient is already right).
  useEffect(() => {
    const target = mode === "compose" ? toRef.current : bodyRef.current;
    target?.focus();
  }, [mode]);

  const fingerprint = useMemo(() => fingerprintOf(form), [form]);

  /**
   * The live warning: the previous attempt's outcome is unknown, and the user
   * has since edited the draft. Sending now would be a second mail on top of
   * a first one that may still arrive.
   */
  const duplicateRisk =
    attempt !== null &&
    (attempt.outcome === "unknown" || attempt.outcome === "inflight") &&
    attempt.fingerprint !== fingerprint;

  function update(patch: Partial<SendForm>): void {
    setForm((current) => ({ ...current, ...patch }));
    setFieldError(null);
  }

  async function addFiles(files: FileList | null): Promise<void> {
    if (!files || files.length === 0) return;
    setAttachmentError(null);
    const next: SendAttachment[] = [];
    let total = form.attachments.reduce((sum, a) => sum + base64ByteLength(a.dataBase64), 0);
    for (const file of Array.from(files)) {
      if (file.size > MAX_ATTACHMENT_BYTES) {
        setAttachmentError(t.compose.attachmentTooLarge);
        continue;
      }
      // Check before committing: adding to the running total first meant a
      // rejected file still counted, so a later file that would have fit was
      // refused too.
      if (total + file.size > MAX_TOTAL_ATTACHMENT_BYTES) {
        setAttachmentError(t.compose.attachmentTotalTooLarge);
        continue;
      }
      const bytes = new Uint8Array(await file.arrayBuffer());
      const dataBase64 = bytesToBase64(bytes);
      total += bytes.length;
      next.push({
        filename: file.name,
        mimeType: file.type || "application/octet-stream",
        dataBase64,
      });
    }
    if (next.length > 0) {
      setForm((current) => ({ ...current, attachments: [...current.attachments, ...next] }));
    }
  }

  async function submit(): Promise<void> {
    if (sending) return;
    const validation = validateForm(mode, form);
    if (!validation.ok) {
      setFieldError({ field: validation.field, reason: validation.reason });
      return;
    }
    setFieldError(null);
    const { requestId } = requestIdFor(attempt, fingerprint, newRequestId);
    setPhase({ kind: "sending" });
    const result = await sendMail(
      mode,
      original?.remoteId ?? "",
      props.accountId,
      form,
      requestId,
    );
    if (result.kind === "sent") {
      setAttempt(null);
      props.onSent({ providerMessageId: result.providerMessageId });
      return;
    }
    if (result.kind === "refused") {
      setAttempt({ requestId, fingerprint, outcome: "refused" });
      setPhase({
        kind: "refused",
        title: sendFailureTitle(result.failure.code),
        detail: result.failure.message,
      });
      return;
    }
    if (result.kind === "inflight") {
      setAttempt({ requestId, fingerprint, outcome: "inflight" });
      setPhase({ kind: "inflight", detail: result.failure.message });
      return;
    }
    setAttempt({ requestId, fingerprint, outcome: "unknown" });
    setPhase({ kind: "unknown", detail: result.message });
  }

  /**
   * Closing a draft that has typed text in it asks first.
   *
   * There is no server-side draft yet, so "close" means "gone": asking is the
   * only thing between a stray Escape and a lost message. An untouched reply
   * is not a draft (its quote is prefilled, not written), so it closes quietly.
   */
  function requestClose(): void {
    if (sending) return;
    if (hasDraftChanges(initial, form)) {
      setConfirmClose(true);
      return;
    }
    props.onClose();
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLDivElement>): void {
    // The window-level shortcuts (palette, archive, delete) must not fire
    // while a draft is open: ⌘K would steal the caret mid-sentence.
    event.stopPropagation();
    if (event.key === "Escape") {
      event.preventDefault();
      requestClose();
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      void submit();
    }
  }

  /**
   * Escape has to work wherever focus is.
   *
   * The sheet's own handler covers the case where focus is inside it. After the
   * discard confirmation closes, focus is back on the document body, and
   * `App`'s window handler deliberately returns early while a composer is
   * open - so without this listener Escape would silently stop working.
   *
   * While the confirmation is up it owns Escape: `ConfirmDialog` stops the
   * event, and the `confirmClose` guard covers the case where focus sits
   * outside the dialog.
   */
  useEffect(() => {
    const onWindowKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || confirmClose) return;
      event.preventDefault();
      requestClose();
    };
    window.addEventListener("keydown", onWindowKeyDown);
    return () => window.removeEventListener("keydown", onWindowKeyDown);
  });

  const attachmentNames = form.attachments.map((a) => a.filename);

  return (
    <div className="scrim compose-scrim" onMouseDown={(event) => {
      if (event.target === event.currentTarget) requestClose();
    }}>
      <div
        className="compose-sheet"
        role="dialog"
        aria-modal="true"
        aria-label={titleOf(mode)}
        onKeyDown={onKeyDown}
      >
        <div className="compose-head">
          <h2>{titleOf(mode)}</h2>
          <span className="spacer" />
          <button className="btn link" onClick={requestClose} disabled={sending} aria-label={t.compose.close}>
            ✕
          </button>
        </div>

        {phase.kind === "refused" ? (
          <Banner tone="error" title={phase.title} detail={phase.detail} />
        ) : null}
        {phase.kind === "unknown" ? (
          <Banner tone="warning" title={t.compose.unknownTitle} detail={phase.detail + " " + t.compose.unknownDetail} />
        ) : null}
        {phase.kind === "inflight" ? (
          <Banner tone="info" title={t.compose.inflightTitle} detail={phase.detail || t.compose.inflightDetail} />
        ) : null}
        {duplicateRisk ? (
          <Banner tone="warning" title={t.compose.duplicateWarning} />
        ) : null}

        <label className="compose-field">
          <span>{t.compose.to}</span>
          <input
            ref={toRef}
            type="text"
            value={form.to}
            placeholder="多个收件人用逗号隔开"
            disabled={sending}
            onChange={(event) => update({ to: event.target.value })}
          />
        </label>

        {showCc ? (
          <>
            <label className="compose-field">
              <span>{t.compose.cc}</span>
              <input
                type="text"
                value={form.cc}
                disabled={sending}
                onChange={(event) => update({ cc: event.target.value })}
              />
            </label>
            <label className="compose-field">
              <span>{t.compose.bcc}</span>
              <input
                type="text"
                value={form.bcc}
                disabled={sending}
                onChange={(event) => update({ bcc: event.target.value })}
              />
            </label>
          </>
        ) : (
          <div className="compose-add-cc">
            <button
              type="button"
              className="btn link"
              disabled={sending}
              onClick={() => setShowCc(true)}
            >
              {t.compose.addCc}
            </button>
          </div>
        )}

        <label className="compose-field">
          <span>{t.compose.subject}</span>
          <input
            type="text"
            value={form.subject}
            disabled={sending}
            onChange={(event) => update({ subject: event.target.value })}
          />
        </label>

        <textarea
          ref={bodyRef}
          className="compose-body"
          value={form.body}
          placeholder={t.compose.bodyPlaceholder}
          disabled={sending}
          onChange={(event) => update({ body: event.target.value })}
        />

        {fieldError ? (
          <div className="compose-field-error" role="alert">
            {fieldError.reason}
          </div>
        ) : null}
        {attachmentError ? (
          <div className="compose-field-error" role="alert">
            {attachmentError}
          </div>
        ) : null}

        <div className="compose-attachments">
          <input
            ref={fileRef}
            type="file"
            multiple
            style={{ display: "none" }}
            onChange={(event) => {
              void addFiles(event.target.files);
              event.target.value = "";
            }}
          />
          <button className="btn" onClick={() => fileRef.current?.click()} disabled={sending}>
            📎 {t.compose.addAttachment}
          </button>
          {attachmentNames.length > 0 ? (
            <span className="chip">{t.compose.attachments(attachmentNames.length)}</span>
          ) : null}
          {form.attachments.map((attachment, index) => (
            <span className="chip" key={attachment.filename + String(index)}>
              {attachment.filename}
              <button
                className="btn link"
                aria-label={t.compose.removeAttachment}
                onClick={() =>
                  setForm((current) => ({
                    ...current,
                    attachments: current.attachments.filter((_, at) => at !== index),
                  }))
                }
              >
                ✕
              </button>
            </span>
          ))}
        </div>

        <div className="compose-actions">
          <button className="btn" onClick={requestClose} disabled={sending}>
            {t.compose.cancel}
          </button>
          <span className="spacer" />
          <button className="btn primary" onClick={() => void submit()} disabled={sending}>
            {sending ? t.compose.sending : t.compose.send}
          </button>
        </div>
      </div>
      <ConfirmDialog
        request={
          confirmClose
            ? {
                title: t.compose.discardTitle,
                message: t.compose.discardMessage,
                confirmLabel: t.compose.discardConfirm,
                destructive: true,
                onConfirm: props.onClose,
              }
            : null
        }
        busy={false}
        onCancel={() => setConfirmClose(false)}
      />
    </div>
  );
}
