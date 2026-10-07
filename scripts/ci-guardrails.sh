#!/usr/bin/env bash
# Per spec §6.6: SQL must be parameterized and secrets must not leak.
# Run from repo root: bash scripts/ci-guardrails.sh
#
# The rule helpers below are pure functions so scripts/test-guardrails.sh can
# source this file and prove the rules against fixtures. Sourcing does not run
# the checks (see the BASH_SOURCE guard at the bottom).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Secret-shaped values. Keep in sync with the fixtures in test-guardrails.sh.
# label|pcre2-pattern|redacted-replacement
SECRET_RULES=(
  'aws-access-key-id|AKIA[0-9A-Z]{16}|AKIA[REDACTED]'
  'google-api-key|AIza[0-9A-Za-z_-]{35}|AIza[REDACTED]'
  'google-oauth-client-secret|GOCSPX-[0-9A-Za-z_-]{20,}|GOCSPX-[REDACTED]'
  'github-token|gh[pousr]_[0-9A-Za-z]{36,}|gh[REDACTED]'
  'private-key-block|-----BEGIN [A-Z ]*PRIVATE KEY-----|[REDACTED PRIVATE KEY HEADER]'
  'openai-key|sk-[A-Za-z0-9]{20,}|sk-[REDACTED]'
)

# ---------------------------------------------------------------------------
# Rule 1: SQL string interpolation outside SQLBuilder.swift.
#
# A Swift string literal is a violation when it contains BOTH a SQL keyword
# (SELECT/INSERT/UPDATE/DELETE, case-insensitive) AND interpolation (`\(` or a
# raw-string `\#(`). The literal may be:
#   (a) a one-line  "SELECT ... \(x)"  /  "select ... \(x)"
#   (b) a multi-line """SELECT ... \(x)"""  /  raw #"SELECT ... \#(x)"#
#   (c) a concatenation  "SELECT " + "\(x)"  /  "SELECT " + x  /  x + "SELECT "
#   (d) a concatenation chain whose UNION spells the statement even though no
#       single literal does — the keyword split across literals ("SEL" + "ECT
#       * FROM t WHERE x = " + v) or parked in a variable (`let kw = "DELETE";
#       kw + " FROM t WHERE x = " + v`).
#
# The old single-line grep regex only matched (a) on one physical line and missed
# the multi-line style that dominates this repo. This scanner tokenizes Swift
# string literals (skipping // and /* */ comments) so literal length/newlines
# do not matter, then checks concatenation chains joined by `+`. Bare `+`
# concatenation of a SQL literal with any expression is flagged on the same
# physical line; a `;` on that line suppresses the match so unrelated
# statements do not trip the rule.
#
# Chain union (shape (d)) — why it is gated on a CONTEXT MARKER and a VALUE
# SPLICE, and why that is not "just widen the regex":
#   The union of a chain's operand texts is the statement Swift actually
#   assembles at run time, so requiring `SQL-keyword AND (FROM|WHERE|VALUES|
#   SET)` over that union catches a keyword that never appears inside one
#   literal. Both gates are load-bearing and were each MEASURED against every
#   Swift file in this repo (207 files), not assumed:
#     * Without the context marker, innocent keyword-free concatenations
#       (`"prefix" + "\(value)"`) start reporting.
#     * Without the value-splice gate the rule is hopeless: `accountColumns +
#       "\n ORDER BY email"` — and every other parameterized multi-line SQL in
#       the stores — chains a SQL body with a suffix literal, safe by
#       construction. A chain fires only when it actually splices a value: an
#       interpolation, a bare identifier, or a trailing `+ operand`.
#     * The `+` gap must stay a single-line expression (no `;`, no newline, no
#       block comment). That is what keeps `accountColumns + "\n WHERE ..."`
#       and the multi-statement `sql:` blocks in the stores out of the union:
#       their literals are separated by real code, not by a concatenation.
#   `IMAPClient.selectVerb` ("SELECT" — a pure literal, no interpolation, no
#   `+`) is untouched by both the literal rule and the chain rule.
#
# One-hop variable resolution (shape (d), form D): `let kw = "DELETE"` binds by
# name, so a chain starting at the identifier `kw` has a head the tokenizer
# never emits. The scan therefore also seeds a chain from a bound identifier
# whose bound text carries a SQL keyword. Restricting this to single-line
# literal bindings keeps it to keyword-shaped constants and avoids folding
# arbitrary locals into every chain.
#
# Returns: 0 = hits (printed), 1 = clean, 2 = scanner error.
sql_hits_for_files() {
  [ "$#" -gt 0 ] || return 1
  local out rc
  if out="$(perl - "$@" <<'PERL'
use strict;
use warnings;

my $SQL    = qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b/i;
my $CTX    = qr/\b(?:FROM|WHERE|VALUES|SET)\b/i;

# ---------------------------------------------------------------------------
# Interpolation is NOT one regex. It is three, selected by the kind of literal
# the tokenizer found, because `\(` means two different things depending on
# which delimiter opened the string:
#
#   plain   (quoted)   a backslash-paren IS interpolation. A hash is not
#                      special here.
#   raw   (1 hash)      backslash-hash-paren IS interpolation; a bare
#                      backslash-paren is just a backslash followed by a paren,
#                      which in practice is a REGEX escape,
#                      a raw regex that matches a literal paren, which is one
#                      of the most common Swift idioms there is.
#   raw   (2 hashes)   backslash-2hash-paren is interpolation; a single
#                      backslash-hash-paren is literal, because the delimiter
#                      took two hashes and the count has to match.
#
# The hash-count rule is SE-0200 and is not guesswork; it was checked against
# swiftc 6.4 by compiling each form and printing the result. With v = VAL:
#     raw 1 hash, backslash-hash-paren     -> interpolated, prints VAL
#     raw 1 hash, backslash-paren          -> literal, prints backslash-paren
#     raw 2 hashes, backslash-2hash-paren  -> interpolated, prints VAL
#     raw 2 hashes, backslash-1hash-paren  -> literal, prints backslash-hash-paren
# So a raw literal interpolates only when the hash run matches its own delimiter
# exactly, which is what has_interp() below encodes.
#
# Why this matters rather than being pedantry: before the split, $INTERP was
# qr/\\#*\(/, which matched `\(` in BOTH kinds. Every regex literal that
# mentions a paren therefore looked like an interpolated SQL string, and
# Tests/LagoonTests/RefreshGateTests.swift was reported on a raw regex
# literal for .insert followed by an escaped paren -- a line with no SQL, no
# interpolation, and no concatenation on it. A guard that cries wolf on the
# repository own test suite is a guard people learn to skip.
#
# The tempting one-character fix is to drop `#*` and match only `\#(`, but that
# would silently disarm every plain string: `"\(x)"` is the single most common
# Swift interpolation there is, and the concat-chain rule below resolves
# `let kw = "DELETE"; kw + " FROM t WHERE x = " + v` through these same
# patterns. The kind is carried on each token instead, so both stay armed.
sub has_interp {
    my ($l) = @_;
    my $kind = $l->{kind} || 'plain';
    my $hashes = defined $l->{hashes} ? $l->{hashes} : 0;

    return $l->{text} =~ /\\\(/          ? 1 : 0   # plain: \( is interpolation
        if $kind eq 'plain';

    # Raw: the delimiter own hash run, and nothing else.
    my $open = '\\' . ('#' x $hashes) . '(';
    return index($l->{text}, $open) >= 0 ? 1 : 0;
}

sub line_of {
    my ($src, $pos) = @_;
    my $prefix = substr($src, 0, $pos);
    return 1 + ($prefix =~ tr/\n//);
}

my $hits = 0;
for my $file (@ARGV) {
    open my $fh, '<', $file or next;
    local $/;
    my $src = <$fh>;
    close $fh;

    my @lits;                       # { line, text, s, e }
    pos($src) = 0;
    while (pos($src) < length($src)) {
        my $start = pos($src);
        if ($src =~ /\G"""/gc) {    # multi-line string open
            my $open_end = pos($src);
            if ($src =~ /\G(.*?)"""/gcs) {
                push @lits, { line => line_of($src, $open_end), text => $1,
                              s => $open_end, e => pos($src),
                              kind => 'plain', hashes => 0 };
            } else { last; }
        } elsif ($src =~ /\G(\#+)"""/gc) {  # raw multi-line (3 quotes + hash run)
            # A raw MULTI-LINE string has to be recognised before the single-line
            # raw branch below, because a one-hash raw literal also matches this
            # prefix and its first two characters. Left to the single-line branch it is
            # mis-bounded: the three opening quotes are read as the opening
            # quote plus two content quotes, and the literal is then closed at
            # the wrong place. That bug
            # was invisible while interpolation was one regex; now that the
            # delimiter decides what an interpolation looks like, a mis-bounded
            # literal would be judged by the wrong rule.
            my $hashes = $1;
            my $open_end = pos($src);
            my $text = '';
            my $closed = 0;
            while (pos($src) < length($src)) {
                if ($src =~ /\G(\.)/gcs) { $text .= $1; next; }
                if ($src =~ /\G"""\Q$hashes\E(?!#)/gc) { $closed = 1; last; }
                my $ch = substr($src, pos($src), 1);
                pos($src) = pos($src) + 1;
                $text .= $ch;
            }
            if ($closed) {
                push @lits, { line => line_of($src, $open_end), text => $text,
                              s => $open_end, e => pos($src),
                              kind => 'raw', hashes => length $hashes };
            } else { last; }
        } elsif ($src =~ /\G(\#+)"/gc) {   # raw string #"…"# / ##"…"##
            # Bound the literal by the matching quote plus hash run so a
            # quote inside a regex character class cannot desynchronize
            # the scan — a desync swallows following code lines and turns
            # their identifiers (e.g. seen.insert) into false SQL hits.
            my $hashes = $1;
            my $open_end = pos($src);
            my $text = '';
            my $closed = 0;
            while (pos($src) < length($src)) {
                if ($src =~ /\G(\.)/gcs) { $text .= $1; next; }        # escaped char keeps backslash (\#( interpolation )
                if ($src =~ /\G"\Q$hashes\E(?!#)/gc) { $closed = 1; last; }
                my $ch = substr($src, pos($src), 1);
                pos($src) = pos($src) + 1;
                $text .= $ch;
            }
            if ($closed) {
                push @lits, { line => line_of($src, $open_end), text => $text,
                              s => $open_end, e => pos($src),
                              kind => 'raw', hashes => length $hashes };
            } else { last; }
        } elsif ($src =~ /\G"/gc) { # single-line string open
            my $open_end = pos($src);
            my $text = '';
            my $closed = 0;
            while (pos($src) < length($src)) {
                if ($src =~ /\G\\(.)/gcs) { $text .= '\\' . $1; next; }
                if ($src =~ /\G"/gc)      { $closed = 1; last; }
                if ($src =~ /\G(.)/gcs)   { $text .= $1; next; }
            }
            if ($closed) {
                push @lits, { line => line_of($src, $open_end), text => $text,
                              s => $open_end, e => pos($src),
                              kind => 'plain', hashes => 0 };
            } else { last; }
        } else {
            if ($src =~ /\G\/\//gc) { $src =~ /\G[^\n]*/gc; next; }  # line comment
            if ($src =~ /\G\/\*/gc) { $src =~ /\G.*?\*\//gcs; next; } # block comment
            pos($src) = $start + 1;
        }
    }

    # Report once per (line, kind); a literal can trip more than one check.
    my %seen;
    my $report = sub {
        my ($line, $kind) = @_;
        return if $seen{"$line:$kind"}++;
        print "$file:$line: $kind\n";
        $hits++;
    };

    for my $i (0 .. $#lits) {
        my $l = $lits[$i];
        next unless $l->{text} =~ $SQL;

        # (a)/(b) the literal itself interpolates a SQL string. has_interp()
        # judges by the kind of delimiter, so a regex escape inside a raw
        # string does not count here.
        if (has_interp($l)) {
            $report->($l->{line}, 'sql-interpolation');
            next;
        }

        # (c) bare `+` concatenation with any expression, on the same physical
        # line and on either side of the SQL literal. A `;` on that line means
        # the `+` belongs to a different statement.
        my $prev_end   = $i == 0 ? 0 : $lits[$i - 1]{e};
        my $next_start = $i == $#lits ? length($src) : $lits[$i + 1]{s};
        my $gap_before = substr($src, $prev_end, $l->{s} - $prev_end);
        my $gap_after  = substr($src, $l->{e}, $next_start - $l->{e});
        my ($before_seg) = $gap_before =~ /([^\n]*)\z/;
        my ($after_seg)  = $gap_after  =~ /\A([^\n]*)/;
        for my $side ($before_seg // '', $after_seg // '') {
            if ($side =~ /\+/ && $side !~ /;/) {
                $report->($l->{line}, 'sql-interpolation-concat');
                last;
            }
        }
    }

    # Concatenation chain across lines: "SELECT ..."\n + "\(x)" — the SQL
    # keyword and the interpolation can sit in different literals.
    for my $i (0 .. $#lits - 1) {
        my $gap = substr($src, $lits[$i]{e}, $lits[$i + 1]{s} - $lits[$i]{e});
        next unless $gap =~ /\+/ && $gap !~ /;/;
        my $union = $lits[$i]{text} . "\n" . $lits[$i + 1]{text};
        # The union is only about SQL; whether it interpolates is asked of the
        # two literals themselves, so a raw-string regex escape on either side
        # stays quiet.
        if ($union =~ $SQL && (has_interp($lits[$i]) || has_interp($lits[$i + 1]))) {
            $report->($lits[$i]{line}, 'sql-interpolation-concat');
        }
    }

    # ---------------------------------------------------------------------
    # Chain union (shape (d)). The two loops above only look INSIDE a single
    # literal, or at a pair of adjacent ones joined by `+` with no `;`. Two
    # real bypasses survive both:
    #
    #   C: "SEL" + "ECT * FROM t WHERE x = " + v
    #      -> no literal contains SELECT; the keyword is split across literals,
    #         so the pair loop sees "SEL" and "ECT * FROM..." and neither half
    #         matches on its own.
    #   D: let kw = "DELETE"; kw + " FROM t WHERE x = " + v
    #      -> worse, the keyword is in a VARIABLE, so it is not a literal at
    #         all and the token stream never sees it.
    #
    # The fix is to evaluate the chain UNION -- the string Swift actually
    # assembles — and require a SQL keyword plus a context marker over it. The
    # `sql-chain-union` kind is separate from the two above so a reader can tell
    # "a literal was dangerous" from "the assembled chain was dangerous".
    #
    # `chain_gap_ok` is deliberately narrow. A `+` here is a concatenation only
    # when the two literals are separated by a single-line expression: no `;`,
    # no block comment, no newline. That single constraint is what keeps
    # `accountColumns + "\n ORDER BY email"` (AccountStore.swift) and the
    # multi-statement `sql:` blocks in the stores out — those literals are
    # separated by real code, never by a `+` expression, so they never become a
    # chain here. Loosening it to "any gap containing a +" was measured and
    # reports 11 false positives on the current tree.
    # Two guards, and the order between them is deliberate:
    #
    #  * The `;` test is the one that carries the weight for multi-statement
    #    code: it is what stops `"SELECT ..." \n let x = f(); sql = "..."` from
    #    being read as a concatenation. It is checked first so the reason is
    #    visible in the reading order rather than hidden behind a broader test.
    #  * The newline test is a second, independent brake on the same input, and
    #    it is the one that subsumes a block-comment test: a /* ... */ comment
    #    in the gap necessarily spans lines, so rejecting any newline already
    #    rejects it. An earlier draft carried a separate m{/\*} guard; it was
    #    removed because no fixture could turn it red on its own, and a guard
    #    nothing can falsify is decoration that reads like coverage.
    #
    # Both are mutation-verified, which for the `;` test means removing the
    # newline test: with it in place the `;` test can never be the deciding one,
    # so a fixture alone cannot prove it. See the M5 note in the test script.
    sub chain_gap_ok {
        my ($gap) = @_;
        return 0 if $gap =~ /;/;
        return 0 if $gap =~ /\n/;
        return 0 unless $gap =~ /\+/;
        return 1;
    }

    # Single-line literal bindings: `let name = "LIT"` / `var name = "LIT"`.
    # Only these are resolved (not multi-line assignments, not computed values):
    # the goal is to see a keyword parked in a constant, not to constant-fold a
    # whole program.
    my %bound;
    my $DQ = chr(34);
    # pos($src) must be reset: the literal tokenizer above leaves it wherever it
    # stopped, and a /g match loop resumes from there instead of 0. Without this
    # the binding scan silently scans from mid-file and finds nothing -- the
    # guard still runs, it just stops seeing the code that matters.
    pos($src) = 0;
    while ($src =~ /\b(?:let|var)\s+([A-Za-z_]\w*)\s*=\s*($DQ(?:[^$DQ\\\n]|\\.)*$DQ)/g) {
        my ($name, $quoted) = ($1, $2);
        (my $text = $quoted) =~ s/\A\Q$DQ\E|\Q$DQ\E\z//g;
        $text =~ s/\\(.)/$1/g;
        $bound{$name} = $text;
    }

    # Walk one candidate chain and report it if the union is dangerous.
    # Returns the index of the last literal consumed so the caller can resume.
    my $scan_chain = sub {
        my ($first, $union_seed, $line) = @_;
        my $j = $first;
        my $union = defined $union_seed ? $union_seed : '';
        my $parts = (defined $union_seed && $union_seed ne '') ? 1 : 0;
        my $splices = 0;

        while ($j <= $#lits) {
            $union .= $lits[$j]{text};
            $parts++;
            # Kind-aware, for the same reason as the call sites above: a raw
            # regex escape in a chained literal is content, not interpolation.
            #
            # Mutation note, stated honestly rather than papered over: replacing
            # this with the old blanket backslash-paren match turns NO fixture
            # red. It is not dead -- it is masked. In every shape where the
            # chain walk sees an interpolating literal, the adjacent-pair rule
            # above has already reported the same file, so the suite cannot
            # isolate this line. It is kept because it is the correct test and
            # because the masking is a property of the pair rule being greedier
            # than the chain rule, not a property of this line being wrong.
            $splices = 1 if has_interp($lits[$j]);

            if ($j == $#lits) {
                # The chain can continue past the LAST literal as `+ operand`
                # ("... WHERE x = " + v). A value spliced there is invisible to
                # the tokenizer, so read it straight off the source.
                my $tail = substr($src, $lits[$j]{e});
                my ($seg) = $tail =~ /\A([^\n;]*)/;
                $seg = '' unless defined $seg;
                if ($seg =~ /\+/) {
                    my $operand = $seg;
                    $operand =~ s/\A\s*\+\s*//;
                    $operand =~ s/\s+\z//;
                    if ($operand ne '' && $operand !~ /\A[(),;\[\]\s.]+\z/) {
                        $splices = 1;
                        $union .= $bound{$operand} if exists $bound{$operand};
                    }
                }
                last;
            }

            my $gap = substr($src, $lits[$j]{e}, $lits[$j + 1]{s} - $lits[$j]{e});
            last unless chain_gap_ok($gap);
            my ($operand) = $gap =~ /([^\n]*)\z/;
            $operand = '' unless defined $operand;
            $operand =~ s/\+\z//;
            $operand =~ s/\A\s+//;
            $operand =~ s/\s+\z//;
            if ($operand =~ /\A[A-Za-z_]\w*\z/) {
                $splices = 1;
                $union .= $bound{$operand} if exists $bound{$operand};
            } elsif ($operand ne '' && $operand !~ /\A[(),;\[\]\s.]+\z/) {
                $splices = 1;
            }
            $j++;
        }

        if ($parts > 1 && $splices && $union =~ $SQL && $union =~ $CTX) {
            $report->($line, 'sql-chain-union');
        }
        return $j;
    };

    # Seed 1: every literal. A lone literal with no `+` never reaches the
    # `parts > 1` gate, so this cannot double-report what the loop above caught.
    my $i = 0;
    while ($i <= $#lits) {
        $i = $scan_chain->($i, undef, $lits[$i]{line}) + 1;
    }

    # Seed 2: a bound identifier used as a chain head (form D). The keyword sits
    # in `let kw = "DELETE"` and the chain proper is `kw + " FROM ..." + v`, so
    # the head literal the tokenizer emits is the FRAGMENT, not the keyword.
    pos($src) = 0;
    while ($src =~ /\b([A-Za-z_]\w*)\s*\+/g) {
        my $name = $1;
        # Read the match offsets NOW: the two guard regexes below reset $-[0],
        # and a stale offset makes the "first literal after the +" search pick
        # the wrong token (it silently selected the keyword literal itself).
        my $match_start = $-[0];
        my $match_end   = $+[0];
        next unless exists $bound{$name};
        next unless $bound{$name} =~ $SQL;
        my $pos = $match_end;
        my $line = 1 + (substr($src, 0, $match_start) =~ tr/\n//);

        my $k;
        for my $idx (0 .. $#lits) {
            if ($lits[$idx]{s} >= $pos) { $k = $idx; last; }
        }
        next unless defined $k;
        # the `+` and the fragment it introduces must be one expression
        my $gap = substr($src, $pos, $lits[$k]{s} - $pos);
        next if $gap =~ /[\n;]/;
        $scan_chain->($k, $bound{$name}, $line);
    }
}
exit($hits ? 1 : 0);
PERL
)"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) return 1 ;;                                    # clean
    1) printf '%s\n' "$out"; return 0 ;;              # hits
    *) echo "guardrail: SQL scanner failed (rc=$rc)" >&2; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Rule 1b: IMAP command assembly under Sources/LagoonServer/IMAP/.
#
# Why this rule exists. Rule 1 watches for SQL, and an IMAP command line is not
# SQL -- but it is the other place in this product where a string reaches a
# network protocol that acts on a real mailbox. `IMAPClient.execute("...")`
# writes the literal to the socket, so anything interpolated into it that is not
# RFC 3501 quoted is an argument-injection primitive: a value carrying CRLF ends
# the command and the next line is a second command the user never asked for.
#
# The gap this closes is specific: rule 1's keyword set is
# SELECT|INSERT|UPDATE|DELETE, so `CREATE`, `STORE`, `MOVE`, `COPY`, `EXPUNGE`,
# `RENAME`, `SUBSCRIBE` were invisible to it. Every one of them mutates mailbox
# state. Today all such values pass through `Self.quoted()` (IMAPClient.swift),
# which refuses control characters and escapes `\` and `"` -- but that was a
# convention, not an enforced one. Nothing failed CI if the next person wrote
# `execute("STORE \(userControlled)")`. That is a guard that reads like
# coverage while checking nothing.
#
# The rule: in a command literal that carries an IMAP verb, every interpolated
# operand must be `quoted()`-derived, unless its shape cannot carry a free-form
# argument. A command with NO interpolation never fires.
#
# That last clause is what keeps `IMAPClient.selectVerb` clean. It is a bare
# `"SELECT"` literal, deliberately split out into a constant (see the comment
# there) precisely because rule 1 cannot tell IMAP SELECT from SQL SELECT. It
# interpolates nothing, so neither rule 1 nor this one touches it.
#
# The exemption list is deliberately shape-based, not name-based. A previous
# draft allowlisted variable names (`payload`, `fieldList`, `set`, `octets`),
# which is the kind of list that rots the moment a name is reused and quietly
# trains a reader to paste new names into it. What is allowed instead is a
# property of the expression that makes injection impossible:
#   - `quoted(...)`                 RFC 3501 quoted-string (the sanctioned path)
#   - `.joined(...)`                a token list built by joining
#   - a variable bound to a `.joined(...)` / `.base64EncodedString()` expression
#                                   one-hop resolution: the joined value cannot
#                                   contain an unescaped quote unless the
#                                   elements did, and base64 cannot contain
#                                   CR, LF or `"` at all
#   - `.count` / a numeric binding or parameter (`uid`, `octets`, ...)
#                                   an integer cannot carry a quote or a CRLF
#   - `static let X` / `Self.X`    a compile-time constant token
# Everything else is reported.
#
# Scope is the command-ASSEMBLY layer. `IMAPConnection.append(mailbox:...)`
# deliberately does NOT re-check its `mailbox`: it is the raw transport, and its
# documented contract is that callers pass an already-quoted value
# (`IMAPClient.append` calls `Self.quoted(mailbox)`). Re-litigating a
# lower-level primitive here would be checking a contract that layer owns.
#
# Returns: 0 = hits (printed), 1 = clean, 2 = scanner error.
imap_command_hits_for_files() {
  [ "$#" -gt 0 ] || return 1
  local out rc
  if out="$(perl - "$@" <<'PERL'
use strict;
use warnings;

# Capture the interpolated expression. The inner class allows ONE level of
# nesting so a call-shaped operand is seen rather than skipped:
# `\(add.joined(separator: " "))` is a real shape at IMAPClient.swift:447, and a
# flat [^()]* silently stops matching at the first inner paren -- the operand
# would then be invisible to this rule, which is the same class of blind spot
# this rule exists to close. Two levels is not needed here and deeper nesting
# only appears in expression shapes that are quoted() or joined() anyway.
my $DQ  = chr(34);
my $ATOM = qr/(?:[^()$DQ]|$DQ(?:[^$DQ\\]|\\.)*$DQ|\((?:[^()]*)\))/;
my $INTERP = qr/\\#*\(($ATOM*)\)/;
my $VERB   = qr/\b(?:CREATE|DELETE|RENAME|SUBSCRIBE|UNSUBSCRIBE|SELECT|EXAMINE
                    |STATUS|APPEND|MOVE|COPY|STORE|SEARCH|FETCH)\b/xi;

my $hits = 0;
for my $file (@ARGV) {
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;
    my $text = join q{}, @lines;

    # Operands whose SHAPE cannot carry a free-form argument. See the rule
    # comment above for why this is shape-based and not a list of names.
    my %safe;
    while ($text =~ /\bstatic\s+(?:let|var)\s+([A-Za-z_]\w*)/g)          { $safe{$1} = 1 }
    while ($text =~ /\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=\s*[^;\n]*\.joined\(/g)          { $safe{$1} = 1 }
    while ($text =~ /\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=\s*[^;\n]*\.base64EncodedString\(/g) { $safe{$1} = 1 }
    while ($text =~ /\b(?:let|var)\s+([A-Za-z_]\w*)\s*:\s*[^=\n]*\b(?:Int|UInt|Int64|Int32|UInt64|UInt32)\b/g) { $safe{$1} = 1 }
    # numeric function PARAMETERS, including a signature split across lines
    while ($text =~ /\b([A-Za-z_]\w*)\s*:\s*(?:Swift\.)?(?:Int|UInt|Int64|Int32|UInt64|UInt32)\b/g) { $safe{$1} = 1 }

    # Literal extraction, paren-depth aware.
    #
    # The obvious matcher (quote, then anything that is not a quote or a
    # backslash) truncates a real line in this repo: at IMAPClient.swift:447 the
    # literal is
    #     "UID STORE \(uid) +FLAGS (\(add.joined(separator: \" \")))"
    # and a flat matcher stops at the quote before the space, handing the rule
    # the text `UID STORE \(uid) +FLAGS (\(add.joined(separator: ` and never
    # looking at the joined flag list at all. An operand the rule cannot see is
    # the exact blind spot this rule exists to close, so the scan below only
    # ends a literal at a quote sitting at interpolation depth 0.
    #
    # DQ is chr(34) rather than a literal quote because an odd number of double
    # quote characters on one line desynchronizes the quote-state scan bash
    # performs over this heredoc while it sits inside a command substitution --
    # see .memory/guardrail-raw-string-tokenizer-desync.md, which records the
    # same class of tokenizer desync in the opposite direction.
    my $BS = chr(92);
    my $literals_in;
    {
        my $dq = $DQ; my $bs = $BS;
        $literals_in = sub {
            my ($line) = @_;
            my @out;
            my $n = length $line;
            my $i = 0;
            while ($i < $n) {
                my $open = index($line, $dq, $i);
                last if $open < 0;
                my $j = $open + 1;
                my $depth = 0;
                my $esc = 0;
                my $lit = q{};
                while ($j < $n) {
                    my $c = substr($line, $j, 1);
                    if ($esc)                { $lit .= $c; $esc = 0; $j++; next }
                    if ($c eq $bs)           { $lit .= $c; $esc = 1; $j++; next }
                    if ($c eq $dq && $depth == 0) { last }
                    if    ($c eq q{(}) { $depth++ }
                    elsif ($c eq q{)}) { $depth-- if $depth > 0 }
                    $lit .= $c;
                    $j++;
                }
                last if $j >= $n;
                push @out, $lit;
                $i = $j + 1;
            }
            return @out;
        };
    }

    my $no = 0;
    for my $line (@lines) {
        $no++;
        for my $lit ($literals_in->($line)) {
            next unless $lit =~ $VERB;
            my @ops;
            while ($lit =~ /$INTERP/g) { push @ops, $1 }
            next unless @ops;
            my @bad;
            for my $op (@ops) {
                my $bare = $op;
                $bare =~ s/\ASelf\.//;
                next if $op =~ /quoted/i;
                next if $op =~ /\.joined\(|\.base64EncodedString\(|\.count\b/;
                next if $bare =~ /\b(?:uid|tag|seq|first|last|startUid|endUid|fromUid|toUid)\z/i;
                next if $safe{$bare};
                push @bad, $op;
            }
            next unless @bad;
            print qq{$file:$no: imap-command-unquoted-operand ops=} . join(q{,}, @bad) . qq{\n};
            $hits++;
        }
    }
}
exit($hits ? 1 : 0);
PERL
)"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) return 1 ;;
    1) printf '%s\n' "$out"; return 0 ;;
    *) echo "guardrail: IMAP command scanner failed (rc=$rc)" >&2; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Rule 2: secret-shaped values in tracked files.
# Prints `rule=<label>` + `file:line:<redacted line>`; never the full secret.
# Returns: 0 = hits, 1 = clean.
# Engine note: this used to shell out to ripgrep. `rg` is NOT a baseline tool --
# stock macOS and the macos-15 GitHub runner do not ship it -- so the whole
# guardrail refused to run in CI and `run-all-tests.sh` died on its first step.
# Every test in the suite was blocked by a scanner that only existed on the
# author's machine. Perl is the right engine here: it is already the parser for
# rule 1, and it is present on every macOS install and every GitHub runner.
#
# Output format matches the previous `rg -n` shape exactly (`file:line:redacted`)
# so the fixtures in scripts/test-guardrails.sh keep pinning the same contract.
secret_hits_for_files() {
  [ "$#" -gt 0 ] || return 1
  local found=0 rule label pattern repl out
  for rule in "${SECRET_RULES[@]}"; do
    IFS='|' read -r label pattern repl <<<"$rule"
    out="$(perl -e '
      use strict; use warnings;
      my ($pattern, $repl) = (shift, shift);
      my $safe = $repl;
      $safe =~ s/\\/\\\\/g; $safe =~ s/\$/\\\$/g; $safe =~ s/\@/\\\@/g;
      my $re = qr/$pattern/;
      for my $file (@ARGV) {
        open my $fh, "<", $file or next;
        binmode $fh;
        my $no = 0;
        while (my $line = <$fh>) {
          $no++;
          chomp $line;
          next unless $line =~ /$re/;
          (my $o = $line) =~ s/$re/$safe/g;
          print "$file:$no:$o\n";
        }
        close $fh;
      }
    ' -- "$pattern" "$repl" "$@" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf 'rule=%s\n%s\n' "$label" "$out"
      found=1
    fi
  done
  [ "$found" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Rule 3: raw to_vector() outside SQL comments / migration files.
# Prints `file:line:content` for hits. Returns: 0 = hits, 1 = clean.
# Same return convention as sql_hits_for_files.
tovector_hits_for_files() {
  [ "$#" -gt 0 ] || return 1
  local out rc
  out="$(perl -e '
    use strict; use warnings;
    my $hit = 0;
    for my $file (@ARGV) {
      next if $file =~ /\.sql$/;
      open my $fh, "<", $file or next;
      my $no = 0;
      while (my $line = <$fh>) {
        $no++;
        next if $line =~ /^\s*--/;
        next unless $line =~ /to_vector\(/;
        print "$file:$no:$line";
        $hit = 1;
      }
      close $fh;
    }
    exit($hit ? 1 : 0);
  ' -- "$@")" && rc=0 || rc=$?
  case "$rc" in
    0) return 1 ;;                                    # clean
    1) printf '%s\n' "$out"; return 0 ;;              # hits
    *) echo "guardrail: to_vector scanner failed (rc=$rc)" >&2; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Rule 4: a filled .env must not be tracked, at any directory depth.
# .env.example is allowed anywhere. Returns 0 = forbidden, 1 = allowed.
env_path_forbidden() {
  local base="${1##*/}"
  case "$base" in
    .env) return 0 ;;
    .env.example) return 1 ;;
    .env.*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
run_all_checks() {
  local fail=0
  local f hits rc

  if ! command -v perl >/dev/null 2>&1; then
    echo "FAIL: perl is required for guardrails (baseline on macOS and GitHub runners)" >&2
    return 1
  fi

  # Rule 1 ------------------------------------------------------------------
  # One filesystem walk feeds rules 1 and 3, and `find` keeps this free of the
  # non-baseline tools that made the guardrail unrunnable in CI.
  local sql_files=()
  local imap_files=()
  local -a all_files=()
  while IFS= read -r f; do
    all_files+=("$f")
    case "${f##*/}" in
      SQLBuilder.swift) ;;
      *.swift) sql_files+=("$f") ;;
    esac
    # Rule 1b is scoped to the IMAP command-ASSEMBLY layer: IMAPClient (which
    # owns the quoted() contract) and IMAPProvider. IMAPConnection is excluded
    # on purpose -- it is the raw transport whose own documented contract is
    # that callers hand it an ALREADY-quoted mailbox
    # (IMAPClient.append calls Self.quoted(mailbox)). Re-checking a lower-level
    # primitive here would fail CI for honouring a contract that layer owns.
    case "${f##*/}" in
      IMAPConnection.swift) ;;
      IMAPClient.swift|IMAPProvider.swift) imap_files+=("$f") ;;
    esac
  done < <(find Sources Tests -type f 2>/dev/null | sort)

  hits="$(sql_hits_for_files "${sql_files[@]}")" && rc=0 || rc=$?
  case "$rc" in
    0)
      echo "FAIL: SQL string interpolation detected outside SQLBuilder.swift" >&2
      printf '%s\n' "$hits" >&2
      fail=1
      ;;
    1) ;;
    *) fail=1 ;;
  esac

  # Rule 1b -----------------------------------------------------------------
  # IMAP command assembly. See imap_command_hits_for_files for why this is not
  # covered by rule 1 (different verbs, and the commands act on a real mailbox).
  if [ "${#imap_files[@]}" -gt 0 ]; then
    hits="$(imap_command_hits_for_files "${imap_files[@]}")" && rc=0 || rc=$?
    case "$rc" in
      0)
        echo "FAIL: IMAP command interpolates an operand that is not quoted()" >&2
        printf '%s\n' "$hits" >&2
        fail=1
        ;;
      1) ;;
      *) fail=1 ;;
    esac
  fi

  # Rule 2 ------------------------------------------------------------------
  local tracked=()
  while IFS= read -r f; do
    if [ "${f##*/}" != ".env.example" ]; then
      tracked+=("$f")
    fi
  done < <(git ls-files 2>/dev/null || true)

  hits="$(secret_hits_for_files "${tracked[@]}")" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: secret-shaped value found in tracked files" >&2
    printf '%s\n' "$hits" >&2
    fail=1
  fi

  # Rule 3: raw to_vector() concatenation outside SQL comments / migrations.
  # Migration .sql files are schema definitions, not query building, and are
  # allowed to call CREATE EXTENSION / define vector columns.
  #
  # NOTE: this rule is currently dead code. `to_vector()` and the whole
  # Postgres/pgvector arm were removed in the V3 embedded-SQLite rebuild, and
  # there is not a single .sql file left in the tree. It is kept (and kept
  # runnable) only so this change stays behaviour-preserving; deleting it is a
  # separate call for the maintainer.
  local tovector_hits
  tovector_hits="$(tovector_hits_for_files "${all_files[@]}")" && rc=0 || rc=$?
  case "$rc" in
    0)
      echo "FAIL: raw to_vector() call found; use \$1::vector binding" >&2
      printf '%s\n' "$tovector_hits" >&2
      fail=1
      ;;
    1) ;;
    *) fail=1 ;;
  esac

  # Rule 4: no tracked .env with secrets, at any depth (allows .env.example).
  local env_hits=""
  while IFS= read -r f; do
    if env_path_forbidden "$f"; then
      env_hits+="$f"$'\n'
    fi
  done < <(git ls-files 2>/dev/null || true)
  if [ -n "$env_hits" ]; then
    echo "FAIL: a filled .env file is tracked" >&2
    printf '%s' "$env_hits" >&2
    fail=1
  fi

  # Rule 6: vendor SDK imports outside Providers/ — deferred to M1 when LagoonAI lands.

  return "$fail"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if run_all_checks; then
    echo "CI guardrails: OK"
    exit 0
  fi
  exit 1
fi
