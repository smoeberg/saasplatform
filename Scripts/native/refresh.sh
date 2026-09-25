#!/usr/bin/env bash
# refresh.sh - SellYourSaaS native refresh action
# Genindlser config og restarter services for en tenant

set -euo pipefail

# Konfiguration
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?Mangler SELLYOURSAAS_INSTANCE_NAME}"

# Sanitize instance name
if [[ ! "$INSTANCE" =~ ^[a-z0-9-]+$ ]]; then
  echo "FATAL: INSTANCE '$INSTANCE' indeholder ugyldige tegn" >&2
  exit 2
fi

# Standard paths
USER_HOME="/home/$INSTANCE"
APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
APACHE_SITES_ENABLED="/etc/apache2/sites-enabled"
PHP_FPM_POOL_DIR="/etc/php/8.2/fpm/pool.d"

# Logging
log() {
  echo "[$(date -Is)] [refresh] [$INSTANCE] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Tjek at bruger findes
if ! id "$INSTANCE" &>/dev/null; then
  fail "Bruger $INSTANCE findes ikke"
fi

# Genindls Apache vhost
log "Genindlser Apache vhost"
VHOST_FILE="$APACHE_SITES_AVAILABLE/${INSTANCE}.conf"

if [[ -f "$VHOST_FILE" ]]; then
  # Deaktiver og genaktiver vhost
  a2dissite "$INSTANCE.conf" 2>/dev/null || true
  a2ensite "$INSTANCE.conf"
  log "Vhost genindlst"
else
  fail "Vhost findes ikke"
fi

# Genindls PHP-FPM pool
log "Genindlser PHP-FPM pool"
FPM_POOL_FILE="$PHP_FPM_POOL_DIR/${INSTANCE}.conf"

if [[ -f "$FPM_POOL_FILE" ]]; then
  # Deaktiver og genaktiver pool
  mv "$FPM_POOL_FILE" "${FPM_POOL_FILE}.refresh"
  mv "${FPM_POOL_FILE}.refresh" "$FPM_POOL_FILE"
  log "FPM pool genindlst"
else
  fail "FPM pool findes ikke"
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
  log "Healthz check: Advarsel"
fi

log "Refresh fuldfrt for $INSTANCE"
exit 0
