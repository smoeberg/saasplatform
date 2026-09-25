#!/usr/bin/env bash
# suspend.sh - SellYourSaaS native suspend action
# Deaktiverer tenant ved at stoppe FPM pool og deaktivere vhost

set -euo pipefail

# Konfiguration
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?Mangler SELLYOURSAAS_INSTANCE_NAME}"

# Sanitize instance name
if [[ ! "$INSTANCE" =~ ^[a-z0-9-]+$ ]]; then
  echo "FATAL: INSTANCE '$INSTANCE' indeholder ugyldige tegn" >&2
  exit 2
fi

# Standard paths
APACHE_SITES_ENABLED="/etc/apache2/sites-enabled"
PHP_FPM_POOL_DIR="/etc/php/8.2/fpm/pool.d"

# Logging
log() {
  echo "[$(date -Is)] [suspend] [$INSTANCE] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Deaktiver Apache vhost
log "Deaktiverer Apache vhost"
VHOST_FILE="$APACHE_SITES_ENABLED/${INSTANCE}.conf"

if [[ -L "$VHOST_FILE" ]]; then
  a2dissite "$INSTANCE.conf"
  log "Vhost deaktiveret"
else
  log "Vhost allerede deaktiveret"
fi

# Stop PHP-FPM pool
log "Stopper PHP-FPM pool"
FPM_POOL_FILE="$PHP_FPM_POOL_DIR/${INSTANCE}.conf"

if [[ -f "$FPM_POOL_FILE" ]]; then
  # Deaktiver pool ved at omdøbe filen
  mv "$FPM_POOL_FILE" "${FPM_POOL_FILE}.disabled"
  log "FPM pool deaktiveret"
else
  log "FPM pool findes ikke"
fi

# Genstart services
log "Genstarter Apache og PHP-FPM"
systemctl restart apache2
systemctl restart php8.2-fpm

log "Suspend fuldført for $INSTANCE"
exit 0
