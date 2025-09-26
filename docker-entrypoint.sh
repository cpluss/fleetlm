#!/bin/bash
set -euo pipefail

APP_BIN="/app/fleetlm/bin/fleetlm"
CMD="${1:-start}"
MIGRATE_ON_BOOT="${MIGRATE_ON_BOOT:-true}"

run_migrations() {
  echo "Running database migrations..."
  "$APP_BIN" eval "Fleetlm.Release.migrate"
}

case "$CMD" in
  start|start_iex|daemon|daemon_iex)
    if [ "${MIGRATE_ON_BOOT}" = "true" ]; then
      run_migrations
    else
      echo "Skipping database migrations because MIGRATE_ON_BOOT=${MIGRATE_ON_BOOT}";
    fi
    ;;
  *)
    # For commands like eval, remote, etc we skip automatic migrations
    ;;
esac

exec "$APP_BIN" "$@"
