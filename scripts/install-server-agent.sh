#!/usr/bin/env bash
# RETIRED (V3 embedded runtime).
#
# The server is now embedded inside the Lagoon app process (LagoonRuntime in
# Sources/LagoonServer/Runtime). There is no separate server binary, no
# Docker Postgres and no LaunchAgent to install.
#
# Uninstalling the OLD agent from a machine that ran the V2 setup (the agent
# kept the old server alive from the repo's .env):
#
#   launchctl bootout gui/$(id -u)/com.lagoon.email.server
#   rm ~/Library/LaunchAgents/com.lagoon.email.server.plist
#
# Old logs remain at ~/Library/Logs/Lagoon/ and the retired Postgres volume
# inside Docker can be removed with `docker compose down -v` from any
# checkout that still has the old docker-compose.yml.
echo "install-server-agent.sh is retired: the app embeds the server. See header for agent uninstall." >&2
exit 1
