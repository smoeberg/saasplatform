#!/usr/bin/env bash
# unsuspend.sh - SellYourSaaS native unsuspend action
# Reaktiverer tenant ved at genaktivere FPM pool og vhost

set -euo pipefail

# Konfiguration
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?Mangler SELLYOURSAAS_INSTANCE_NAME}"

# Sanitize instance name
if [[ ! "$INSTANCE" =~ ^[a-z0-9-]+$ ]]; then
  echo "FATAL: INSTANCE '$INSTANCE' indeholder ugyldige tegn" >&2
  exit 2
fi

# Standard paths
APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
APACHE_SITES_ENABLED="/etc/apache2/sites-enabled"
PHP_FPM_POOL_DIR="/etc/php/8.2/fpm/pool.d"

# Logging
log() {
  echo "[$(date -Is)] [unsuspend] [$INSTANCE] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Genaktiver PHP-FPM pool
log "Genaktiverer PHP-FPM pool"
FPM_POOL_FILE="$PHP_FPM_POOL_DIR/${INSTANCE}.conf"
DISABLED_FILE="${FPM_POOL_FILE}.disabled"

if [[ -f "$DISABLED_FILE" ]]; then
  mv "$DISABLED_FILE" "$FPM_POOL_FILE"
  log "FPM pool genaktiveret"
elif [[ -f "$FPM_POOL_FILE" ]]; then
  log "FPM pool er allerede aktiv"
else
  fail "FPM pool findes ikke (hverken aktiv eller deaktiveret)"
fi

# Aktiver Apache vhost
log "Aktiverer Apache vhost"
VHOST_FILE="$APACHE_SITES_AVAILABLE/${INSTANCE}.conf"

if [[ -f "$VHOST_FILE" && ! -L "$APACHE_SITES_ENABLED/${INSTANCE}.conf" ]]; then
  a2ensite "$INSTANCE.conf"
  log "Vhost aktiveret"
elif [[ -L "$APACHE_SITES_ENABLED/${INSTANCE}.conf" ]]; then
  log "Vhost er allerede aktiv"
else
  fail "Vhost findes ikke"
fi

# Genstart services
log "Genstarter Apache og PHP-FPM"
systemctl restart apache2
systemctl restart php8.2-fpm

# Verificer healthz
DOMAIN="${SELLYOURSAAS_DOLIBARRINSTANCE_URL:-}"
DOMAIN="${DOMAIN#*://}"
DOMAIN="${DOMAIN%/}"

if curl -fsS -o /dev/null -m 5 "http://$DOMAIN/healthz" 2>/dev/null; then
  log "Healthz check: OK"
else
  log "Healthz check: Advarsel (kan skyldes DNS)"
fi

log "Unsuspend fuldført for $INSTANCE"
exit 0
