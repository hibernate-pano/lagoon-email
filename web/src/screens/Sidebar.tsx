/**
 * The navigation column (Sidebar.swift:89-105).
 *
 * Same single-value model as v3: the route *is* the destination, so "which
 * surface am I looking at" cannot disagree between the sidebar and the pane
 * (v3's RootView.swift:143-145 derives the surface the same way).
 *
 * Counts: a bucket whose count is unknown renders as "—", never as 0 — that is
 * checklist §2's "「不知道」不显示成 0" and v3's Sidebar.swift:188-211 rule
 * ("the badge is omitted at zero rather than shown as 0").
 */
import type { ReactNode } from "react";
import { t } from "../l10n/zh";
import type { LensId, Route } from "../core/router";

interface Destination {
  lens: LensId | "briefing" | "decisions";
  label: string;
  glyph: string;
  countKey?: string;
}

const SMART: Destination[] = [
  // The decision board is first because it is the screen that asks for the
  // fewest decisions: opening the app onto a list is opening it onto 430 rows.
  { lens: "decisions", label: t.sidebar.decisions, glyph: "◆", countKey: "decisions" },
  { lens: "briefing", label: t.sidebar.briefing, glyph: "▦" },
  { lens: "inbox", label: t.sidebar.inbox, glyph: "▤", countKey: "live" },
  { lens: "unread", label: t.sidebar.unread, glyph: "✉", countKey: "unread" },
  { lens: "pinned", label: t.sidebar.pinned, glyph: "⌖", countKey: "pinned" },
];

const PLACES: Destination[] = [
  { lens: "archived", label: t.sidebar.archived, glyph: "▣", countKey: "archived" },
  { lens: "sent", label: t.sidebar.sent, glyph: "➤", countKey: "sent" },
  { lens: "trash", label: t.sidebar.trash, glyph: "⌫", countKey: "deleted" },
];

function countText(counts: Record<string, number> | undefined, key: string | undefined): string | null {
  if (!key) return null;
  const value = counts?.[key];
  if (value === undefined) return "—";
  if (value === 0) return null;
  return String(value);
}

export interface SidebarProps {
  route: Route;
  counts?: Record<string, number>;
  onNavigate: (route: Route) => void;
  disabled: boolean;
}

function Row(props: {
  destination: Destination;
  active: boolean;
  counts?: Record<string, number>;
  disabled: boolean;
  onNavigate: (route: Route) => void;
}): ReactNode {
  const { destination, active, counts, disabled, onNavigate } = props;
  const count = countText(counts, destination.countKey);
  const go = () => {
    if (destination.lens === "decisions") onNavigate({ view: "decisions", lens: "inbox" });
    else if (destination.lens === "briefing") onNavigate({ view: "briefing", lens: "inbox" });
    else onNavigate({ view: "list", lens: destination.lens as LensId });
  };
  return (
    <button
      type="button"
      className="sidebar-row"
      aria-current={active}
      disabled={disabled}
      onClick={go}
    >
      <span className="glyph" aria-hidden="true">
        {destination.glyph}
      </span>
      <span className="label">{destination.label}</span>
      {count ? <span className="count">{count}</span> : null}
    </button>
  );
}

export function Sidebar(props: SidebarProps): ReactNode {
  const { route } = props;
  const activeLens: Destination["lens"] =
    route.view === "decisions" ? "decisions" : route.view === "briefing" ? "briefing" : route.lens;
  return (
    <nav className="sidebar" aria-label={t.sidebar.navigation}>
      <section>
        <h2>{t.sidebar.smartViews}</h2>
        {SMART.map((destination) => (
          <Row
            key={destination.lens}
            destination={destination}
            active={activeLens === destination.lens}
            counts={props.counts}
            disabled={props.disabled}
            onNavigate={props.onNavigate}
          />
        ))}
      </section>
      <section>
        <h2>{t.sidebar.places}</h2>
        {PLACES.map((destination) => (
          <Row
            key={destination.lens}
            destination={destination}
            active={activeLens === destination.lens}
            counts={props.counts}
            disabled={props.disabled}
            onNavigate={props.onNavigate}
          />
        ))}
      </section>
      <p className="sidebar-foot">{t.sidebar.hint}</p>
    </nav>
  );
}
