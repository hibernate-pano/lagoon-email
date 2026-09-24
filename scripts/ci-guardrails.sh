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
#
# The old single-line rg regex only matched (a) on one physical line and missed
# the multi-line style that dominates this repo. This scanner tokenizes Swift
# string literals (skipping // and /* */ comments) so literal length/newlines
# do not matter, then checks concatenation chains joined by `+`. Bare `+`
# concatenation of a SQL literal with any expression is flagged on the same
# physical line; a `;` on that line suppresses the match so unrelated
# statements do not trip the rule.
#
# Returns: 0 = hits (printed), 1 = clean, 2 = scanner error.
sql_hits_for_files() {
  [ "$#" -gt 0 ] || return 1
  local out rc
  if out="$(perl - "$@" <<'PERL'
use strict;
use warnings;

my $SQL    = qr/\b(?:SELECT|INSERT|UPDATE|DELETE)\b/i;
my $INTERP = qr/\\#*\(/;

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
                              s => $open_end, e => pos($src) };
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
                              s => $open_end, e => pos($src) };
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
                              s => $open_end, e => pos($src) };
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

        # (a)/(b) the literal itself interpolates a SQL string.
        if ($l->{text} =~ $INTERP) {
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
        if ($union =~ $SQL && $union =~ $INTERP) {
            $report->($lits[$i]{line}, 'sql-interpolation-concat');
        }
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
# Rule 2: secret-shaped values in tracked files.
# Prints `rule=<label>` + `file:line:<redacted line>`; never the full secret.
# Returns: 0 = hits, 1 = clean.
secret_hits_for_files() {
  [ "$#" -gt 0 ] || return 1
  local found=0 rule label pattern repl out
  for rule in "${SECRET_RULES[@]}"; do
    IFS='|' read -r label pattern repl <<<"$rule"
    out="$(printf '%s\0' "$@" \
      | xargs -0 rg -n --with-filename --no-heading --no-ignore --text --pcre2 \
          -e "$pattern" -r "$repl" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf 'rule=%s\n%s\n' "$label" "$out"
      found=1
    fi
  done
  [ "$found" -eq 1 ]
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

  if ! command -v rg >/dev/null 2>&1; then
    echo "FAIL: ripgrep (rg) is required for guardrails" >&2
    return 1
  fi

  # Rule 1 ------------------------------------------------------------------
  local sql_files=()
  while IFS= read -r f; do
    if [ "${f##*/}" != "SQLBuilder.swift" ]; then
      sql_files+=("$f")
    fi
  done < <(rg --files Sources Tests -g '*.swift' 2>/dev/null || true)

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
  if rg -n --pcre2 'to_vector\(' Sources Tests 2>/dev/null \
     | rg -v '\.sql:' \
     | rg -v '^\s*--' > /tmp/lagoon-tovector.txt; then
    if [ -s /tmp/lagoon-tovector.txt ]; then
      echo "FAIL: raw to_vector() call found; use \$1::vector binding" >&2
      cat /tmp/lagoon-tovector.txt >&2
      fail=1
    fi
  fi

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
