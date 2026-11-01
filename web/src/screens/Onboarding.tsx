/**
 * The connect form — the only write M1 allows (task-6 §3, checklist §2).
 *
 * POST /api/accounts/imap {provider, email, authCode} creates a *local* account
 * row after a single IMAP LOGIN probe. It does not change the mailbox. That
 * distinction is printed on the form, because "connect your mailbox" and
 * "let this app act on your mailbox" are different promises and the user is
 * entitled to know which one they are making.
 *
 * Validation is local on purpose: a 16-character auth code is checked before the
 * request, so a typo does not cost an IMAP round trip (and cannot be mistaken for
 * "auth failed" when it was really "malformed"). Server failures are then shown
 * by *code*, which is checklist §2's requirement.
 */
import { useState, type ReactNode } from "react";
import { apiCall } from "../core/api";
import { describeConnectFailure } from "../core/errors";
import type { ConnectedAccount } from "../core/types";
import { Banner } from "../ui/atoms";
import { t } from "../l10n/zh";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const AUTH_CODE_PATTERN = /^[A-Za-z0-9]{16}$/;

export interface OnboardingProps {
  sidecarLabel: string;
  onConnected: (account: ConnectedAccount) => void;
  onOpenPalette: () => void;
}

export function Onboarding(props: OnboardingProps): ReactNode {
  const [email, setEmail] = useState("");
  const [authCode, setAuthCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    if (!EMAIL_PATTERN.test(email.trim())) {
      setError(t.onboarding.validationEmail);
      return;
    }
    if (!AUTH_CODE_PATTERN.test(authCode.trim())) {
      setError(t.onboarding.validationAuthCode);
      return;
    }
    setBusy(true);
    // The only POST this milestone makes. provider is fixed to "qq": the product
    // is a QQ-only triage tool (task brief), and inventing a provider picker for
    // a provider the server would 503 on is a lie with a dropdown.
    const result = await apiCall<ConnectedAccount>({
      method: "POST",
      path: "/api/accounts/imap",
      body: { provider: "qq", email: email.trim(), authCode: authCode.trim() },
    });
    setBusy(false);
    if (result.kind === "ok") {
      props.onConnected(result.data);
      return;
    }
    if (result.kind === "fail") {
      setError(result.message);
      return;
    }
    setError(describeConnectFailure(result.code, result.status));
  };

  return (
    <div className="center-wrap">
      <div className="center-card">
        <h1>{t.onboarding.title}</h1>
        <p>{t.onboarding.detail}</p>
        <p className="surface-detail">{props.sidecarLabel}</p>
        <p className="surface-detail">{t.onboarding.emptyDbNote}</p>

        <h2 style={{ fontSize: "var(--fs-title)", margin: "var(--sp-md) 0 0" }}>{t.onboarding.connectTitle}</h2>
        <form onSubmit={submit} noValidate>
          <div className="field">
            <label htmlFor="email">{t.onboarding.email}</label>
            <input
              id="email"
              type="email"
              autoComplete="off"
              spellCheck={false}
              placeholder={t.onboarding.emailPlaceholder}
              value={email}
              onChange={(event) => setEmail(event.target.value)}
            />
          </div>
          <div className="field">
            <label htmlFor="authCode">{t.onboarding.authCode}</label>
            <input
              id="authCode"
              type="password"
              autoComplete="off"
              placeholder={t.onboarding.authCodePlaceholder}
              value={authCode}
              onChange={(event) => setAuthCode(event.target.value)}
            />
            <span className="hint">{t.onboarding.authCodeHint}</span>
          </div>
          <div style={{ display: "flex", gap: "var(--sp-sm)" }}>
            <button className="btn primary" type="submit" disabled={busy}>
              {busy ? t.onboarding.submitting : t.onboarding.submit}
            </button>
            <button className="btn" type="button" onClick={props.onOpenPalette}>
              ⌘K
            </button>
          </div>
        </form>
        {error ? <Banner tone="error" title={t.onboarding.errorTitle} detail={error} onDismiss={() => setError(null)} /> : null}
        <p className="surface-detail">{t.onboarding.readOnlyNote}</p>
      </div>
    </div>
  );
}
