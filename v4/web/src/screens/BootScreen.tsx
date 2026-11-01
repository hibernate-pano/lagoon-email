/**
 * The boot screen (six-state: 加载中 / 错误), contract §3 and §4.1.
 *
 * v3's equivalent is LagoonApp.swift:20-77 — five branches, each with its own
 * screen, and the Keychain-blocked branch exists because showing the *connect*
 * form to a user who already has a mailbox told them to re-enter credentials
 * and then overwrote them. The Web version has the same branch shape and the
 * same rule: never offer an action that can destroy what is already there.
 */
import type { ReactNode } from "react";
import { t } from "../l10n/zh";
import { sidecarUrl } from "virtual:sidecar-env";
import type { BootState } from "../core/hooks";

export function BootScreen(props: { boot: BootState; phase: "starting" | "failed" }): ReactNode {
  const { boot, phase } = props;
  return (
    <div className="center-wrap">
      <div className="center-card" role={phase === "failed" ? "alert" : "status"}>
        {phase === "starting" ? (
          <>
            <div className="spinner" aria-hidden="true" />
            <h1>{t.boot.starting}</h1>
            <p>{t.boot.startingDetail}</p>
          </>
        ) : (
          <>
            <h1>{t.boot.failedTitle}</h1>
            <p>{boot.detail ?? t.boot.transportFailed}</p>
            <div className="surface-actions">
              <button className="btn primary" onClick={boot.retry}>
                {t.boot.retry}
              </button>
            </div>
            <p>
              {t.boot.hintStart}
              <br />
              <code>{t.boot.hintCommand}</code>
            </p>
          </>
        )}
        <details>
          <summary className="surface-detail">{t.boot.diagnostics}</summary>
          <div className="diag">
            <span>{t.boot.transportLabel}</span>
            <code>{boot.transport}</code>
            <span>{t.boot.endpointLabel}</span>
            <code>{sidecarUrl || t.boot.noEndpoint}</code>
          </div>
        </details>
      </div>
    </div>
  );
}
