#!/usr/bin/env python3
"""Probe a real QQ Mailbox over IMAP and report what Lagoon would resolve.

Why this exists: the 19 IMAPProvider unit tests all run against a scripted
fake server, so they prove the logic but not that QQ Mail's wire behaviour
matches the assumptions. Two of those assumptions are load-bearing and only
observable against the real server:

  1. `resolveArchiveFolder` matches folder names against
     {"archive", "归档"} and `resolveTrashFolder` against a similar list.
     QQ Mail's folders carry Chinese names, which RFC 3501 §5.1.3 puts on
     the wire as modified UTF-7 ("归档" -> "&X1JoYw-"). IMAPResponseParser
     deliberately does not decode anything ("everything else is passed
     through untouched"), so if QQ does send UTF-7, every Chinese name
     arrives mangled and the archive/trash match fails — Lagoon would
     create a second "Archive" folder and answer 409 on delete.
  2. The mail volume Lagoon has to sync.

This script reads the authorization code with getpass (never echoed, never
written to a file, never passed on a command line) and prints the server's
raw LIST lines alongside the decoded name and the verdict Lagoon would
reach. It touches no project code and no database.

Usage:  python3 scripts/probe-qq.py [address]
        (press enter at the address prompt to accept the argument)
"""

from __future__ import annotations

import base64
import getpass
import os
import re
import socket
import ssl
import sys

# Overridable so the script can be pointed at a local stub (and at 163, which
# shares the IMAP path) without editing it.
HOST = os.environ.get("LAGOON_PROBE_HOST", "imap.qq.com")
PORT = int(os.environ.get("LAGOON_PROBE_PORT", "993"))

# Mirrors IMAPProvider.resolveArchiveFolder / resolveTrashFolder exactly, so
# the verdict below is the real code path, not a paraphrase of it.
ARCHIVE_NAMES = {"archive", "归档"}
TRASH_NAMES = {
    "trash", "deleted", "deleted messages", "deleted items",
    "已删除", "已删除邮件",
}
# Mirrors diagnosticSentContains.
SENT_NAMES = {"sent", "sent messages", "已发送", "已发送邮件"}

LIST_RE = re.compile(
    rb'^\* LIST \((?P<attrs>[^)]*)\)\s+(?P<delim>\S+)\s+'
    rb'(?P<name>"(?:[^"\\]|\\.)*"|\S+)'
)


def decode_mutf7(raw: str) -> str:
    """Modified UTF-7 (RFC 3501 §5.1.3) -> str. Returns input unchanged when
    it is not UTF-7, which is itself a useful signal."""
    if "&" not in raw:
        return raw
    out: list[str] = []
    i = 0
    while i < len(raw):
        ch = raw[i]
        if ch != "&":
            out.append(ch)
            i += 1
            continue
        end = raw.find("-", i)
        if end == -1:
            out.append(raw[i:])
            break
        chunk = raw[i + 1:end]
        if chunk == "":
            out.append("&")
        else:
            try:
                padded = chunk + "=" * (-len(chunk) % 4)
                out.append(base64.b64decode(padded).decode("utf-16-be", errors="replace"))
            except Exception:
                out.append(raw[i:end + 1])  # not really UTF-7; keep verbatim
        i = end + 1
    return "".join(out)


def unquote(token: str) -> str:
    if len(token) >= 2 and token[0] == '"' and token[-1] == '"':
        return re.sub(r'\\(.)', r'\1', token[1:-1])
    return token


def imap_quote(value: str, label: str) -> str:
    """Quote an IMAP argument exactly the way IMAPClient.quoted does, so this
    script and the product agree. Rejecting control characters is what stops a
    pasted value from appending a second command to the LOGIN line; escaping
    backslash and quote keeps the argument intact. A code pasted with either
    character would otherwise surface as a confusing authentication failure."""
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise ValueError(f"{label} contains a control character (newline/tab?)")
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


class Imap:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buf = b""
        self.tag = 0

    def readline(self) -> bytes:
        while b"\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("server closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def send(self, command: str) -> str:
        self.tag += 1
        tag = f"p{self.tag:03d}"
        self.sock.sendall(f"{tag} {command}\r\n".encode())
        lines: list[bytes] = []
        while True:
            line = self.readline()
            lines.append(line)
            if line.startswith(tag.encode() + b" "):
                break
        return "\n".join(line.decode("utf-8", errors="replace") for line in lines)


def main() -> int:
    address = sys.argv[1] if len(sys.argv) > 1 else ""
    if not address:
        address = input("QQ 邮箱地址: ").strip()
    if not address:
        print("no address given", file=sys.stderr)
        return 2

    print("授权码 (不回显; 取 QQ 邮箱网页版 设置->账户->IMAP/SMTP 服务):")
    code = getpass.getpass("  ").strip()
    if not code:
        print("no authorization code given", file=sys.stderr)
        return 2

    context = ssl.create_default_context()
    try:
        raw_sock = socket.create_connection((HOST, PORT), timeout=15)
    except OSError as exc:
        print(f"cannot reach {HOST}:{PORT} — {exc}", file=sys.stderr)
        return 1
    with context.wrap_socket(raw_sock, server_hostname=HOST) as tls:
        imap = Imap(tls)

        greeting = imap.readline().decode("utf-8", errors="replace")
        print(f"\ngreeting: {greeting}")
        if not greeting.upper().startswith("* OK"):
            print("server did not greet with OK", file=sys.stderr)
            return 1

        caps = imap.send("CAPABILITY")
        print(f"\ncapabilities:\n{caps}")

        # Same command IMAPClient.login falls back to. SASL-IR is tried first
        # in the product; LOGIN is what this script needs because the failure
        # text is what we want to see.
        try:
            login = imap.send(f"LOGIN {imap_quote(address, 'address')} "
                              f"{imap_quote(code, 'authorization code')}")
        except ValueError as exc:
            print(f"\nrefusing to send: {exc}", file=sys.stderr)
            return 2
        if re.search(r"^p\d+ NO", login, re.MULTILINE):
            print(f"\nLOGIN failed:\n{login}")
            print(
                "\nQQ reports one flat error for: wrong code, account disabled, "
                "IMAP service off, and rate-limiting. Lagoon maps a rejected "
                "LOGIN to its 「授权码错误」 hint regardless of which it was."
            )
            return 1
        print(f"\nLOGIN ok:\n{login}")

        listing = imap.send('LIST "" "*"')
        print("\nraw LIST lines (what the parser actually receives):")
        for line in listing.splitlines():
            if not line.upper().startswith("* LIST"):
                continue
            print(f"  {line}")

        print("\nwhat Lagoon resolves (it does NOT decode UTF-7 — matching uses "
              "the wire name):")
        archive_hit = trash_hit = sent_hit = None
        archive_would_match = trash_would_match = sent_would_match = None
        mailboxes: list[tuple[str, str, list[str]]] = []
        for line in listing.splitlines():
            m = LIST_RE.match(line.encode("utf-8", errors="replace"))
            if not m:
                continue
            attrs = m.group("attrs").decode().split()
            # IMAPClient.listMailboxes takes `response.atoms.last`, i.e. the
            # unquoted mailbox name exactly as the server wrote it.
            wire = unquote(m.group("name").decode("utf-8", errors="replace"))
            decoded = decode_mutf7(wire)
            mailboxes.append((wire, decoded, attrs))

            roles = []
            if any(a.lower() == "\\archive" for a in attrs) or wire.lower() in ARCHIVE_NAMES:
                roles.append("ARCHIVE")
                archive_hit = wire
            if any(a.lower() == "\\trash" for a in attrs) or wire.lower() in TRASH_NAMES:
                roles.append("TRASH")
                trash_hit = wire
            if any(a.lower() == "\\sent" for a in attrs) or wire.lower() in SENT_NAMES:
                roles.append("SENT")
                sent_hit = wire

            # Same test again, but against the decoded name: this is what the
            # code was clearly written to expect ("归档" is in the list).
            if decoded != wire:
                if decoded.lower() in ARCHIVE_NAMES:
                    archive_would_match = decoded
                if decoded.lower() in TRASH_NAMES:
                    trash_would_match = decoded
                if decoded.lower() in SENT_NAMES:
                    sent_would_match = decoded

            utf7_flag = "   [wire is modified UTF-7]" if decoded != wire else ""
            role_txt = ("   <-- " + ",".join(roles)) if roles else ""
            print(f"  wire {wire!r}  decodes to {decoded!r}{utf7_flag}{role_txt}")
            other = [a for a in attrs if a.lower() in ("\\archive", "\\trash", "\\sent")]
            if other and not roles:
                print(f"      special-use present: {', '.join(other)}")

        print("\nverdict (Lagoon's real behaviour):")
        for label, hit, would, consequence in (
            ("archive", archive_hit, archive_would_match,
             "Lagoon would CREATE a second 'Archive' folder; the existing one stays untouched"),
            ("trash  ", trash_hit, trash_would_match,
             "delete answers 409 delete-unavailable"),
            ("sent   ", sent_hit, sent_would_match,
             "reply-threading loses its Sent scan"),
        ):
            line = f"  {label} -> {hit!r}" if hit else f"  {label} -> NO MATCH: {consequence}"
            print(line)
            if not hit and would:
                print(f"      !! name-only match would have hit on {would!r} — "
                      f"the special-use attribute is what saves it here")

        missing_role = [r for r, h in (("archive", archive_hit), ("trash", trash_hit),
                                       ("sent", sent_hit)) if not h]
        if missing_role:
            print(f"\n  roles rescued by special-use attributes: "
                  f"{', '.join(r for r in ('archive', 'trash', 'sent') if r not in missing_role) or 'none'}")

        select = imap.send("SELECT INBOX")
        exists = re.search(r"\* (\d+) EXISTS", select)
        unseen = re.search(r"\* (\d+) UNSEEN", select)
        print(f"\nINBOX: {exists.group(1) if exists else '?'} messages, "
              f"{unseen.group(1) if unseen else '?'} unseen")

        # Archiving needs UID MOVE; the capability block above should have it.
        print(f"\ntotal folders: {len(mailboxes)}")
        imap.send("LOGOUT")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (EOFError, OSError, ssl.SSLError) as exc:
        print(f"\nprobe aborted: {exc}", file=sys.stderr)
        sys.exit(1)
