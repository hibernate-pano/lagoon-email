/**
 * The selection model shared by the list and the briefing.
 *
 * One function so the two surfaces cannot disagree about what a verb targets:
 * an explicit multi-selection wins, then the opened message, then the keyboard
 * cursor. Empty means "nothing is targeted" - a verb must then do nothing
 * rather than guess a row the user cannot see.
 */
export function targetIdsOf(
  selection: Set<string>,
  openedId: string | null,
  cursor: string | null,
): string[] {
  if (selection.size > 0) return [...selection];
  if (openedId) return [openedId];
  if (cursor) return [cursor];
  return [];
}
