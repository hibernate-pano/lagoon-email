/**
 * Command palette skeleton (CommandPaletteView.swift:80-142 in v3, which has 12
 * commands; M1 ships the navigation half).
 *
 * Keyboard contract: ⌘K opens, ↑/↓ move, Enter runs, Esc closes. Nothing here
 * claims a system shortcut — ⌘N/⌘T/⌘W/⌘Q are left to the shell and the browser
 * (checklist §2).
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { LensId } from "../core/router";
import { t } from "../l10n/zh";

export interface PaletteCommand {
  id: string;
  label: string;
  hint?: string;
  run: () => void;
}

export function CommandPalette(props: {
  commands: PaletteCommand[];
  onClose: () => void;
}): ReactNode {
  const [query, setQuery] = useState("");
  const [highlight, setHighlight] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return props.commands;
    return props.commands.filter((command) => command.label.toLowerCase().includes(needle));
  }, [props.commands, query]);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    setHighlight((current) => Math.min(current, Math.max(0, filtered.length - 1)));
  }, [filtered.length]);

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setHighlight((current) => Math.min(current + 1, Math.max(0, filtered.length - 1)));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setHighlight((current) => Math.max(current - 1, 0));
    } else if (event.key === "Enter") {
      event.preventDefault();
      filtered[highlight]?.run();
    } else if (event.key === "Escape") {
      event.preventDefault();
      props.onClose();
    }
  };

  return (
    <div className="scrim" onMouseDown={(event) => { if (event.target === event.currentTarget) props.onClose(); }}>
      <div className="palette" role="dialog" aria-modal="true" aria-label={t.palette.placeholder} onKeyDown={onKeyDown}>
        <input
          ref={inputRef}
          value={query}
          placeholder={t.palette.placeholder}
          aria-label={t.palette.placeholder}
          onChange={(event) => setQuery(event.target.value)}
        />
        <div className="palette-list" role="listbox">
          {filtered.length === 0 ? (
            <div className="palette-empty">{t.palette.noMatch}</div>
          ) : (
            filtered.map((command, index) => (
              <button
                key={command.id}
                type="button"
                role="option"
                aria-selected={index === highlight}
                className="palette-item"
                onMouseEnter={() => setHighlight(index)}
                onClick={command.run}
              >
                <span>{command.label}</span>
                {command.hint ? <span className="hint">{command.hint}</span> : null}
              </button>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

/** Built from the same route table the sidebar uses — one source, no drift. */
export function buildCommands(handlers: {
  go: (view: "briefing" | "list", lens: LensId) => void;
  openShortcuts: () => void;
  openStates: () => void;
  openConnect: () => void;
  close: () => void;
}): PaletteCommand[] {
  return [
    { id: "briefing", label: t.palette.openBriefing, run: () => handlers.go("briefing", "inbox") },
    { id: "inbox", label: t.palette.openInbox, run: () => handlers.go("list", "inbox") },
    { id: "unread", label: t.palette.openUnread, run: () => handlers.go("list", "unread") },
    { id: "pinned", label: t.palette.openPinned, run: () => handlers.go("list", "pinned") },
    { id: "archived", label: t.palette.openArchived, run: () => handlers.go("list", "archived") },
    { id: "sent", label: t.palette.openSent, run: () => handlers.go("list", "sent") },
    { id: "trash", label: t.palette.openTrash, run: () => handlers.go("list", "trash") },
    { id: "connect", label: t.palette.connect, run: handlers.openConnect },
    { id: "shortcuts", label: t.palette.shortcuts, hint: "⌘/", run: handlers.openShortcuts },
    { id: "states", label: t.palette.states, run: handlers.openStates },
  ];
}
