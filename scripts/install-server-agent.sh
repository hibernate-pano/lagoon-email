#!/usr/bin/env bash
# Build and install a per-user LaunchAgent that keeps the Lagoon server running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.lagoon.email.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Lagoon"

if [ ! -f "$ROOT/.env" ]; then
  echo "Missing $ROOT/.env" >&2
  exit 1
fi

swift build -c release --product LagoonServer
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>cd "$ROOT" &amp;&amp; set -a &amp;&amp; source .env &amp;&amp; set +a &amp;&amp; export DATABASE_URL="\${DATABASE_URL:-postgres://lagoon:lagoon@127.0.0.1:5433/lagoon}" &amp;&amp; exec "$ROOT/.build/release/LagoonServer"</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/server.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/server.error.log</string>
</dict>
</plist>
EOF

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# bootout can return before launchd has fully removed the old service. Booting
# the replacement in immediately can fail with a transient I/O error and leave
# the plist installed but no process running.
for _ in {1..50}; do
  if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null || true

echo "Installed and started $LABEL"
echo "Logs: $LOG_DIR/server.log"
