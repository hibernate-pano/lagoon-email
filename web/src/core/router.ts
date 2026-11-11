/**
 * Hash routing: one URL shape for "where am I", so a reload (and Playwright)
 * lands on the same screen.
 *
 *   #/decisions           (the default surface: the few things to settle)
 *   #/briefing
 *   #/list/inbox | unread | pinned | archived | sent | trash
 *   #/dev/states          (component gallery — example data, clearly labelled)
 *
 * v3 derives the surface from the sidebar destination (RootView.swift:143-145);
 * the same single source of truth is here: the route *is* the destination.
 */
export type LensId = "inbox" | "unread" | "pinned" | "archived" | "sent" | "trash";
export type ViewId = "decisions" | "briefing" | "list" | "states";

export interface Route {
  view: ViewId;
  lens: LensId;
}

const LENSES: LensId[] = ["inbox", "unread", "pinned", "archived", "sent", "trash"];

export function parseHash(hash: string): Route {
  const clean = hash.replace(/^#\/?/, "");
  const [head, second] = clean.split("/");
  if (head === "decisions" || head === "") return { view: "decisions", lens: "inbox" };
  if (head === "briefing") return { view: "briefing", lens: "inbox" };
  if (head === "list") {
    const lens = LENSES.find((candidate) => candidate === second) ?? "inbox";
    return { view: "list", lens };
  }
  if (head === "dev" && second === "states") return { view: "states", lens: "inbox" };
  // An unknown hash lands on the decisions board: the surface that asks the
  // user for the fewest decisions is the safest default.
  return { view: "decisions", lens: "inbox" };
}

export function hashFor(route: Route): string {
  if (route.view === "states") return "#/dev/states";
  if (route.view === "list") return "#/list/" + route.lens;
  if (route.view === "briefing") return "#/briefing";
  return "#/decisions";
}

export function navigate(route: Route): void {
  const next = hashFor(route);
  if (window.location.hash !== next) window.location.hash = next;
}
