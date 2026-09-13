#!/usr/bin/env bash
set -euo pipefail

LABEL="com.lagoon.email.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed $LABEL"
