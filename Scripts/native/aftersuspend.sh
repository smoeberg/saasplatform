#!/usr/bin/env bash
# aftersuspend.sh - SellYourSaaS native post-suspend action
# Skriver statusfil for at indikere at tenant er suspended

set -euo pipefail

# Konfiguration
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?Mangler SELLYOURSAAS_INSTANCE_NAME}"
STATUS_DIR="${STATUS_DIR:-/var/lib/saasplatform/status}"

# Sanitize instance name
if [[ ! "$INSTANCE" =~ ^[a-z0-9-]+$ ]]; then
  echo "FATAL: INSTANCE '$INSTANCE' indeholder ugyldige tegn" >&2
  exit 2
fi

# Logging
log() {
  echo "[$(date -Is)] [aftersuspend] [$INSTANCE] $*"
}

# Opret status directory
mkdir -p "$STATUS_DIR"

# Skriv suspended status
STATUS_FILE="$STATUS_DIR/${INSTANCE}.status"
echo "suspended" > "$STATUS_FILE"

log "Status skrevet: suspended -> $STATUS_FILE"

exit 0
