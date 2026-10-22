#!/usr/bin/env bash
# Sign a .app bundle with an identity whose designated requirement survives
# a rebuild, and say plainly what happened.
#
# ## Why the signature identity matters more than anything else here
#
# A file-based Keychain item's access list is bound to the *code signature*
# of the app that created it. The binding key is the app's **designated
# requirement**:
#
#   * ad-hoc signed  → the requirement is `cdhash H"…"` — the hash of this
#     exact build. The next build has a different hash, the stored access
#     list no longer matches, and macOS raises an authorization prompt that
#     a background `SecurityAgent` can never show. The read blocks in
#     `mach_msg2_trap` forever: the app sits on 「服务器启动中」 with no
#     window and no listening port.
#   * signed with a certificate → the requirement is
#     `identifier "com.lagoon.email" and anchor apple generic and
#     certificate leaf[subject.CN] = "…"` — stable across rebuilds. The
#     stored access list keeps matching, and the secret is readable with no
#     prompt at all.
#
# So the signature identity is not a packaging detail here. It decides
# whether the user's saved secrets survive the next rebuild.
#
# ## Why the identity is chosen by SHA-1, not by name
#
# `security find-identity` lists two *identically named* "Apple Development"
# certificates on the machine that reported this. `codesign --sign "Apple
# Development: someone@example.com (8J7TT5DXWD)"` is ambiguous between them
# and silently picks one. Worse, the one it picks may be **revoked** — and
# an app signed with a revoked certificate is killed by the OS the moment it
# touches the Keychain (`SIGKILL`, exit 137), which looks exactly like a
# crash and is not one. A SHA-1 fingerprint is unambiguous, so that is what
# this script selects on.
#
# ## Why revocation is checked, and not assumed
#
# A revoked certificate still appears in `security find-identity` as a
# "valid identity" — that list says the *private key* is present and the
# chain is well-formed, not that Apple has not withdrawn the certificate.
# The only reliable check is to ask the system's own evaluator:
# `spctl --assess` reports `CSSMERR_TP_CERT_REVOKED` for a revoked
# certificate. This script signs a throwaway probe and asks.
#
# ## The fallback, and why it is loud
#
# When no usable certificate exists, the build falls back to ad-hoc signing
# — and says so, in those words, because the consequence is not cosmetic:
# every rebuild will re-prompt for the `lagoon.*` secrets, and an
# unanswered prompt looks like a hung app. A silent fallback is how this
# bug survived in the first place.
#
# Usage: scripts/sign-app.sh <app-path>
# Env:   LAGOON_CODESIGN_IDENTITY — a SHA-1 fingerprint (preferred) or a
#                                codesigning identity name. Overrides the
#                                automatic choice.

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "usage: scripts/sign-app.sh <app-path>" >&2
  exit 2
fi
if [[ ! -d "$APP" ]]; then
  echo "sign-app.sh: $APP does not exist" >&2
  exit 2
fi

# The bundle identifier is part of the designated requirement, so the
# requirement is only stable if the identifier is stable. Read it out of
# the bundle rather than hard-coding it.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"

# --- 1. Candidate identities -------------------------------------------------
#
# `security find-identity -v -p codesigning` prints one line per identity as
# `  N) <SHA1> "<name>"`. The SHA-1 is what we want; the name is only a
# label and is not unique on this machine.

identity_shas() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9]*) \([0-9A-F]\{40\}\) ".*$/\1/p'
}

identity_name() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^[[:space:]]*[0-9]*) $1 \"\(.*\)\"\$/\1/p" | head -1
}

# --- 2. Is this certificate usable? -----------------------------------------
#
# Two ways it can be unusable, and both are silent if you do not check:
#   * revoked        → the app is SIGKILLed on its first Keychain call
#   * not a code-signing identity → codesign refuses it
#
# The probe is a throwaway copy of the real executable: the verdict depends
# on the certificate, and probing with the real binary would leave a
# half-signed bundle behind if the check failed.
#
# The probe is signed with `--force --sign -` first so that the ad-hoc
# signature it starts with cannot mask a revocation verdict.

certificate_is_usable() {
  local sha="$1" probe
  probe="$(mktemp -t lagoonsign.XXXXXX)"
  # Any valid Mach-O will do; the system binary is signed by Apple and is
  # not revocable, so it must be re-signed with the candidate first.
  cp /bin/echo "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
  codesign --force --sign - "$probe" >/dev/null 2>&1 || { rm -f "$probe"; return 1; }
  if ! codesign --force --sign "$sha" "$probe" >/dev/null 2>&1; then
    return 1
  fi
  # The system's own trust evaluator is the only authority on revocation.
  # `spctl --assess` on a revoked certificate prints CSSMERR_TP_CERT_REVOKED.
  local verdict
  verdict="$(spctl --assess --type execute --verbose=4 "$probe" 2>&1 || true)"
  rm -f "$probe"
  case "$verdict" in
    *CSSMERR_TP_CERT_REVOKED*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- 3. Pick an identity ----------------------------------------------------

pick_identity() {
  local explicit="${LAGOON_CODESIGN_IDENTITY:-}"
  local sha

  if [[ -n "$explicit" ]]; then
    # An explicit override is honoured as given, but it is still checked:
    # an explicit request for a revoked certificate should fail loudly here
    # rather than produce an app that dies on launch.
    sha="$explicit"
    if [[ ! "$sha" =~ ^[0-9A-Fa-f]{40}$ ]]; then
      # Not a fingerprint — treat it as a name and resolve it.
      sha="$(identity_shas | while read -r s; do
               [[ "$(identity_name "$s")" == "$explicit" ]] && { echo "$s"; break; }
             done)"
    fi
    if [[ -z "$sha" ]]; then
      echo "sign-app.sh: LAGOON_CODESIGN_IDENTITY='$explicit' matches no codesigning identity" >&2
      return 2
    fi
    if ! certificate_is_usable "$sha"; then
      echo "sign-app.sh: the requested identity $sha is unusable (revoked or not a codesigning identity)" >&2
      return 2
    fi
    echo "$sha"
    return 0
  fi

  while read -r sha; do
    [[ -z "$sha" ]] && continue
    if certificate_is_usable "$sha"; then
      echo "$sha"
      return 0
    fi
    echo "sign-app.sh: skipping $(identity_name "$sha") ($sha) — revoked or unusable" >&2
  done < <(identity_shas)
  return 1
}

# The designated requirement, as text.
#
# `codesign -d -r-` prints it in one of two shapes depending on the signer's
# mood: `designated => …` or `# designated => …`. Both have to be handled,
# because the second shape is what an ad-hoc signature produces — and that
# is precisely the case this script has to report accurately.
requirement_text() {
  codesign -d -r- "$1" 2>&1 \
    | grep -o 'designated => .*' \
    | sed 's/^designated => //' \
    | tail -1
}

# --- 4. Sign ----------------------------------------------------------------

# `pick_identity` returns 2 when an explicitly requested identity is
# unusable. That is a hard error, not a reason to fall back: the user asked
# for a specific certificate, and quietly signing with something else (or
# ad-hoc) would hide the fact that what they asked for does not work.
set +e
SIGN_SHA="$(pick_identity)"
PICK_STATUS=$?
set -e
if [[ $PICK_STATUS -eq 2 ]]; then
  echo "sign-app.sh: refusing to sign with the requested identity." >&2
  exit 1
fi

if [[ -n "$SIGN_SHA" ]]; then
  codesign --force --deep --sign "$SIGN_SHA" "$APP"
  REQUIREMENT="$(requirement_text "$APP")"
  # A requirement that still names a cdhash means the signature did not take
  # the way it was supposed to. Say so instead of shipping it quietly.
  if [[ "$REQUIREMENT" == *cdhash* ]]; then
    echo "sign-app.sh: signed with $SIGN_SHA but the requirement is still cdhash-bound:" >&2
    echo "  $REQUIREMENT" >&2
    exit 1
  fi
  echo "Signed $APP"
  echo "  identity:    $(identity_name "$SIGN_SHA") ($SIGN_SHA)"
  echo "  requirement: $REQUIREMENT"
  if [[ -n "$BUNDLE_ID" ]]; then
    echo "  bundle id:   $BUNDLE_ID"
  fi
  echo "  Keychain items written by this build stay readable after the next rebuild."
else
  codesign --force --deep --sign - "$APP"
  REQUIREMENT="$(requirement_text "$APP")"
  echo "WARNING: no usable code-signing certificate on this machine — signed AD-HOC." >&2
  echo "WARNING:   requirement: $REQUIREMENT" >&2
  echo "WARNING:   This requirement is the hash of THIS build. Every rebuild mints a" >&2
  echo "WARNING:   new hash, so the Keychain items lagoon.tokenKey / lagoon.bodyKey /" >&2
  echo "WARNING:   lagoon.envJSON will no longer match their stored access lists." >&2
  echo "WARNING:   macOS will then ask for permission to read them — from a background" >&2
  echo "WARNING:   SecurityAgent with no window, which looks exactly like a hung app." >&2
  echo "WARNING:   To fix this, install an Apple Development certificate and make sure" >&2
  echo "WARNING:   it is not revoked (check: spctl --assess --type execute <signed-binary>)." >&2
  echo "Signed $APP (ad-hoc)"
fi
