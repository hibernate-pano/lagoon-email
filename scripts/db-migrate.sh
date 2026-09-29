#!/usr/bin/env bash
# RETIRED (V3 embedded storage).
#
# The app now runs its own embedded SQLite store (GRDB) and applies its
# schema in-process at startup (Sources/LagoonKit/LagoonDatabase.swift).
# There is no Postgres, no Docker and no migration runner to invoke: this
# script is kept only as a pointer so old muscle memory and stale docs
# resolve somewhere honest.
#
# Historical note: the 19 SQL files under Sources/LagoonKit/Migrations are
# the consolidated record of the Postgres schema; the SQLite schema in
# LagoonDatabase.swift is its final state, expressed for SQLite. Nothing
# migrates from the old Postgres database — remote mail re-syncs from the
# provider, and rules/pins are recreated on first use.
echo "db-migrate.sh is retired: schema is applied automatically by the embedded SQLite store." >&2
exit 1
