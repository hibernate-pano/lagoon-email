#!/usr/bin/env bash
# Capture the golden HTTP fixtures for the sidecar API contract.
#
# Spawns a throwaway lagoon-api (own port, own SQLite file under mktemp, fresh
# ephemeral keys), seeds it with synthetic rows, records the *real* responses
# into tests/contract/fixtures/, then stops the sidecar.
#
#   bash scripts/capture-contract.sh
#   LAGOON_CONTRACT_FIXTURES=/tmp/my-fixtures bash scripts/capture-contract.sh
#
# Guarantees:
#   * never reads or writes .dev/data, the user's store, or any mail server;
#   * no network egress: the seeded account's credentials blob is unreadable, so
#     every provider path fails at credential decryption before a socket exists;
#   * no third-party dependencies: bash + python3 + curl + openssl only.
set -euo pipefail

LAGOON_LABEL=capture-contract
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HARNESS="$LAGOON_ROOT/tests/contract/harness.py"
FIXTURES="${LAGOON_CONTRACT_FIXTURES:-$LAGOON_ROOT/tests/contract/fixtures}"

[ -f "$HARNESS" ] || die "missing $HARNESS"
require_tool python3
require_tool openssl
require_tool curl

BIN="$(sidecar_bin)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lagoon-contract-capture.XXXXXX")"
trap cleanup_sidecar EXIT INT TERM
start_sidecar "$BIN" "$TMP"

echo "capture-contract: sidecar on 127.0.0.1:$SIDECAR_PORT (temp db, ephemeral keys)"
python3 -B "$HARNESS" capture \
  --base-url "http://127.0.0.1:$SIDECAR_PORT" \
  --token "$API_TOKEN" \
  --db "$TMP/lagoon.sqlite" \
  --body-key "$BODY_KEY" \
  --out "$FIXTURES"

echo "capture-contract: done. Verify with: bash scripts/contract-check.sh"
