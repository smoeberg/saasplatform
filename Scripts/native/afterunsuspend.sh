#!/usr/bin/env bash
# afterunsuspend.sh - SellYourSaaS native post-unsuspend action
# Skriver statusfil for at indikere at tenant er unsuspended

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
  echo "[$(date -Is)] [afterunsuspend] [$INSTANCE] $*"
}

# Opret status directory
mkdir -p "$STATUS_DIR"

# Skriv deployed status (unsuspended = deployed)
STATUS_FILE="$STATUS_DIR/${INSTANCE}.status"
echo "deployed" > "$STATUS_FILE"

log "Status skrevet: deployed -> $STATUS_FILE"

# Verificer healthz
DOMAIN="${SELLYOURSAAS_DOLIBARRINSTANCE_URL:-}"
DOMAIN="${DOMAIN#*://}"
DOMAIN="${DOMAIN%/}"

if curl -fsS -o /dev/null -m 5 "http://$DOMAIN/healthz" 2>/dev/null; then
  log "Healthz check: OK"
else
  log "ADVARSEL: Healthz check fejlede"
fi

exit 0
