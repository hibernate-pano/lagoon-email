#!/bin/bash
# Cross-implementation proof: Rust (aes-gcm) <-> Swift (CryptoKit), same envelope.
#   lgb1: + base64( 12B nonce || ciphertext || 16B tag )
# Test vector key only (32 x '0'..'f' ASCII), NOT a real Keychain key.
set -u
cd "$(dirname "$0")"
KEY_B64=$(printf '0123456789abcdef0123456789abcdef' | base64)
RUST=./target/debug/cipher-interop
echo "key_b64=$KEY_B64   (test vector, not the Keychain key)"
echo

run_case () {
  local label="$1" plain="$2"
  echo "### case: $label"
  echo "plaintext      : $plain"
  rust_out=$($RUST encrypt "$KEY_B64" "$plain")
  env=$(printf '%s\n' "$rust_out" | sed -n 's/^ENVELOPE=//p')
  nonce=$(printf '%s\n' "$rust_out" | sed -n 's/^NONCE_HEX=//p')
  echo "rust nonce_hex : $nonce"
  echo "rust envelope  : $env"
  swift_out=$(swift interop.swift open "$KEY_B64" "$env" 2>&1)
  echo "swift decrypt  : $swift_out"
  if [ "$swift_out" = "PLAINTEXT=$plain" ]; then echo "RESULT A (rust->swift): PASS"; else echo "RESULT A (rust->swift): FAIL"; fi

  swift_seal=$(swift interop.swift seal "$KEY_B64" "$plain" 2>&1)
  env2=$(printf '%s\n' "$swift_seal" | sed -n 's/^ENVELOPE=//p')
  echo "swift envelope : $env2"
  rust_back=$($RUST decrypt "$KEY_B64" "$env2" 2>&1)
  echo "rust decrypt   : $rust_back"
  if [ "$rust_back" = "PLAINTEXT=$plain" ]; then echo "RESULT B (swift->rust): PASS"; else echo "RESULT B (swift->rust): FAIL"; fi
  echo
}

run_case "ascii" "hello lagoon v4"
run_case "cjk+emoji" "你好，Lagoon —— 中文正文 🚀 with ascii tail"
run_case "empty-string" ""

echo "### case: tamper (bit flip in ciphertext, must be rejected by both)"
env=$($RUST encrypt "$KEY_B64" "tamper me" | sed -n 's/^ENVELOPE=//p')
bad=$(python3 - "$env" <<'PY'
import base64, sys
env = sys.argv[1]
raw = bytearray(base64.b64decode(env[len("lgb1:"):]))
raw[20] ^= 0x01                      # flip one ciphertext byte
print("lgb1:" + base64.b64encode(bytes(raw)).decode())
PY
)
echo "tampered env   : $bad"
echo "rust  : $($RUST decrypt "$KEY_B64" "$bad" 2>&1)"
echo "swift : $(swift interop.swift open "$KEY_B64" "$bad" 2>&1)"
echo

echo "### case: envelope-prefix guard"
echo "rust  : $($RUST decrypt "$KEY_B64" "not-an-envelope" 2>&1)"
echo
echo "### versions"
grep -A1 -E '^name = "(aes-gcm|aead|aes|ghash|base64)"' Cargo.lock | grep -E 'name|version' | paste - -
