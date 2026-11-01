/**
 * The one prop every surface takes for write verbs.
 *
 * Instead of threading eight callbacks (and their capability hints) through
 * three components, the surfaces take one object. It also gives the capability
 * gate exactly one home, so a new verb cannot be added to a row without also
 * deciding what its disabled state says.
 */
import type { SingleVerb } from "./writes";

/** Verbs a row can request. pin/read are their own endpoints, not "single". */
export type RowVerb = SingleVerb | "pin" | "unpin" | "markRead" | "markUnread";

export interface WriteBridge {
  busy: boolean;
  canArchive: boolean;
  canDelete: boolean;
  canPurge: boolean;
  /** Why the verb is off — shown as a tooltip, never as a silent disabled button. */
  archiveHint?: string;
  deleteHint?: string;
  purgeHint?: string;
  /** One row. */
  row: (verb: RowVerb, remoteId: string) => void;
  /** The current selection. */
  bulk: (verb: "archive" | "delete") => void;
  /** Selection size, so a surface can decide whether to show the bar. */
  selectionCount: number;
  clearSelection: () => void;
}
