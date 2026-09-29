#!/usr/bin/env bash
#
# Lint guard from spec §6.5: no silent `catch` in the client view layer.
# Every failure must surface as an `ErrorBanner`, an
# `ErrorCenter.shared.report(...)`, or a `throw`, so the UI never swallows a
# user action without a word.
#
# WHY THIS IS A PARSER AND NOT A GREP
# The first version of this rule was
#     grep -rnE 'catch \{\s*\}|catch \{ /\* (silently|non-fatal|…) '
# which could never fire on real code. `grep` is line-based, so `\s*` cannot
# span a newline, and the form Swift actually formats — the catch brace, then
# the comment on the next line, then the closing brace — is invisible to it.
# It reported "✅ No silent catches" over 47 `catch {` occurrences in the view
# layer without having examined a single one: a guardrail that always passes
# is worse than no guardrail, because it reads like coverage. So this matches
# braces, the same way scripts/ci-guardrails.sh does for SQL literals.
#
# A catch is "silent" when its body is empty or contains nothing but comments.
# A body that assigns state (`self.banner = nil`, `task.cancel()`) is real
# handling and is left alone.
#
# Run from the repo root. Exit 0 = clean, 1 = violation.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The script goes to a file rather than into `$( … <<'PERL' … )`: nested
# inside a command substitution, bash mis-parses the perl's parentheses and
# the substitution dies with "Substitution pattern not terminated".
scan_out="$(mktemp)"
trap 'rm -f "$scan_out"' EXIT

perl - Sources/Lagoon/Views/*.swift > "$scan_out" <<'PERL'
use strict;
use warnings;

my $violations = 0;
for my $file (@ARGV) {
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;

    my $depth = 0;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        my $code = $line;
        # Drop line comments and string literals so a brace or the word
        # "catch" inside them cannot drive the scan.
        $code =~ s{//.*$}{};
        $code =~ s{/\*.*?\*/}{}g;
        $code =~ s!"(?:[^"\\]|\\.)*"!""!g;

        if ($code =~ /\bcatch\b/) {
            # Count braces from `catch` onward, not from the start of the
            # line: the usual shape is `} catch {`, and counting the whole
            # line nets to zero — the `do {` closer cancels the catch opener
            # and every real body then reads as empty.
            my @body;
            my ($tail) = $code =~ /(\bcatch\b.*)/;
            my $d = 0;
            if (defined $tail) {
                $d = ($tail =~ tr/{//) - ($tail =~ tr/}//);
                # The body can live on the catch line itself — `catch { return }`
                # is real handling, not a swallow — so read the inline text
                # between the catch's braces before walking forward.
                my $inline = $tail;
                $inline =~ s/^\s*catch\b[^{]*\{//;
                # The catch's body ends on this line whenever the depth is not
                # positive — 0 for a bare `catch { }`, negative when an
                # enclosing `}` is also on the line (`} catch { } }` nets -1
                # because $tail starts at `catch`). Everything from the body's
                # own closing brace onward is enclosing syntax, not a
                # statement; keeping that stray `}` is what let every
                # single-line empty catch pass as "handled".
                $inline =~ s/\}.*$// if $d <= 0;
                push @body, $inline if $inline =~ /\S/;
            }
            my $j = $i + 1;
            while ($d > 0 && $j <= $#lines) {
                my $c = $lines[$j];
                $c =~ s{//.*$}{};
                $c =~ s{/\*.*?\*/}{}g;
                $c =~ s!"(?:[^"\\]|\\.)*"!""!g;
                $d += ($c =~ tr/{//) - ($c =~ tr/}//);
                # The line that takes the depth back to zero is the catch's
                # own closing brace, not a statement — drop it before asking
                # whether the body was empty. A line that merely *contains*
                # the closer (`banner = .init()`) still counts.
                $c =~ s/\}\s*$// if $d == 0;
                push @body, $c if $c =~ /\S/;
                $j++;
            }
            # A body with no statement at all is a swallow.
            my $statements = grep { /\S/ } @body;
            if ($statements == 0) {
                $violations++;
                printf("%s:%d: catch with an empty or comment-only body\n", $file, $i + 1);
            }
            $i = $j - 1;
            next;
        }
        $depth += ($code =~ tr/{//) - ($code =~ tr/}//);
    }
}
print "$violations\n";
PERL

violations="$(tail -1 "$scan_out")"
details="$(sed '$d' "$scan_out")"

if [ "${violations:-0}" -ne 0 ]; then
    echo "❌ Silent catch detected in Sources/Lagoon/Views/ (spec §6.5):"
    echo "$details"
    echo ""
    echo "Allowed alternatives: ErrorBanner, ErrorCenter.shared.report(...), or throw."
    exit 1
fi

echo "✅ No silent catches in Sources/Lagoon/Views/"
