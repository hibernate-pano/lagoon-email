/**
 * The keyboard sheet. M1 has four bindings; the table lists exactly those and
 * says so, because v3's lesson was that a cheatsheet teaching a key that is
 * bound nowhere is worse than no cheatsheet at all
 * (Sources/Lagoon/Views/ShortcutsSheet.swift:18-24 — "a ghost key in a
 * cheatsheet is worse than no cheatsheet").
 */
import type { ReactNode } from "react";
import { t } from "../l10n/zh";

const ROWS: { keys: string; label: string }[] = [
  { keys: "⌘K", label: t.shortcuts.palette },
  { keys: "↑ ↓", label: t.shortcuts.move },
  { keys: "Enter", label: t.shortcuts.open },
  { keys: "Esc", label: t.shortcuts.close },
  { keys: "⌘/", label: t.shortcuts.title },
];

export function ShortcutsDialog(props: { onClose: () => void }): ReactNode {
  return (
    <div className="scrim" onMouseDown={(event) => { if (event.target === event.currentTarget) props.onClose(); }}>
      <div className="sheet" role="dialog" aria-modal="true" aria-label={t.shortcuts.title}>
        <h2>{t.shortcuts.title}</h2>
        <table>
          <tbody>
            {ROWS.map((row) => (
              <tr key={row.keys}>
                <td><kbd>{row.keys}</kbd></td>
                <td>{row.label}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="surface-detail" style={{ marginTop: "var(--sp-md)" }}>{t.shortcuts.scopeNote}</p>
        <div style={{ marginTop: "var(--sp-md)" }}>
          <button className="btn" onClick={props.onClose}>{t.six.dismiss}</button>
        </div>
      </div>
    </div>
  );
}
