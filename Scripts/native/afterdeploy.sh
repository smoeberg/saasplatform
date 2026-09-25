#!/usr/bin/env bash
# afterdeploy.sh - SellYourSaaS native post-deploy action
# Skriver statusfil for at indikere at tenant er deployed

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
  echo "[$(date -Is)] [afterdeploy] [$INSTANCE] $*"
}

# Opret status directory
mkdir -p "$STATUS_DIR"

# Skriv deployed status
STATUS_FILE="$STATUS_DIR/${INSTANCE}.status"
echo "deployed" > "$STATUS_FILE"

log "Status skrevet: deployed -> $STATUS_FILE"

# Verificer at bruger findes
if ! id "$INSTANCE" &>/dev/null; then
  log "ADVARSEL: Bruger $INSTANCE findes ikke"
  exit 1
fi

# Verificer healthz
DOMAIN="${SELLYOURSAAS_DOLIBARRINSTANCE_URL:-}"
DOMAIN="${DOMAIN#*://}"
DOMAIN="${DOMAIN%/}"

if curl -fsS -o /dev/null -m 5 "http://$DOMAIN/healthz" 2>/dev/null; then
  log "Healthz check: OK"
else
  log "ADVARSEL: Healthz check fejlede (kan skyldes DNS)"
fi

exit 0
