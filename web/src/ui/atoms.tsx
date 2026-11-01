/**
 * Small shared surfaces. Kept together because each one is <30 lines and each
 * one exists to stop a specific v3 failure from being re-implemented per screen:
 *   Banner      — one banner at a time (NoticeBanner.swift:180-211, INV-6)
 *   OfflineStrip— offline is a *state*, not a failure (OfflineStrip.swift:1-17)
 *   TriBadge    — the capability three-state (MailCapabilities.swift:7-30)
 *   Avatar      — SenderAvatar.swift, initials + stable colour
 */
import type { ReactNode } from "react";
import { triFromGate, triLabel, type TriState } from "../core/async";
import { avatarColorVar, initialsOf } from "./format";
import { t } from "../l10n/zh";

export type BannerTone = "info" | "success" | "warning" | "error";

export function Banner(props: {
  tone: BannerTone;
  title: string;
  detail?: string;
  action?: ReactNode;
  onDismiss?: () => void;
}): ReactNode {
  return (
    <div className={"banner " + props.tone} role={props.tone === "error" ? "alert" : "status"}>
      <span className="banner-title">{props.title}</span>
      {props.detail ? <span>{props.detail}</span> : null}
      <span className="spacer" />
      {props.action}
      {props.onDismiss ? (
        <button className="btn link" onClick={props.onDismiss} aria-label={t.six.dismiss}>
          ✕
        </button>
      ) : null}
    </div>
  );
}

export function OfflineStrip(): ReactNode {
  return (
    <div className="offline-strip" role="status">
      <span aria-hidden="true">◍</span>
      <span>{t.six.offline}</span>
    </div>
  );
}

/**
 * The capability three-state.
 *
 * The label for "unknown" says 未探测 and the title says why it is not a "no":
 * that sentence is the whole point of the third state, and printing "不支持"
 * for an unprobed capability is the bug that disabled archive for a release.
 */
export function TriBadge(props: { label: string; gate: boolean | null | undefined }): ReactNode {
  const state: TriState = triFromGate(props.gate);
  const className = state === "allowed" ? "chip ok" : state === "denied" ? "chip err" : "chip unknown";
  const title = state === "unknown" ? t.six.notProbedHint : undefined;
  return (
    <span className={className} title={title}>
      {props.label}: {triLabel(state)}
    </span>
  );
}

export function Avatar(props: { email: string; name?: string | null; size?: number }): ReactNode {
  const style = {
    background: avatarColorVar(props.email),
    width: props.size ?? undefined,
    height: props.size ?? undefined,
  };
  return (
    <span className="avatar" style={style} aria-hidden="true">
      {initialsOf(props.email, props.name)}
    </span>
  );
}

export function Chip(props: { children: ReactNode; tone?: "warn" | "ok" | "err" | "unknown" }): ReactNode {
  return <span className={"chip " + (props.tone ?? "")}>{props.children}</span>;
}
