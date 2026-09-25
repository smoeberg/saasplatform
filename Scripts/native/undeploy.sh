#!/usr/bin/env bash
# undeploy.sh - SellYourSaaS native undeploy action
# Sletter Unix-bruger, database, vhost, og FPM pool for en tenant

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
CHROOT_BASE="/var/www/chroot"

# Logging
log() {
  echo "[$(date -Is)] [undeploy] [$INSTANCE] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Deaktiver Apache vhost
log "Deaktiverer Apache vhost"
VHOST_FILE="$APACHE_SITES_AVAILABLE/${INSTANCE}.conf"

if [[ -L "$APACHE_SITES_ENABLED/${INSTANCE}.conf" ]]; then
  a2dissite "$INSTANCE.conf"
  log "Vhost deaktiveret"
else
  log "Vhost allerede deaktiveret"
fi

# Slet FPM pool
log "Sletter PHP-FPM pool"
FPM_POOL_FILE="$PHP_FPM_POOL_DIR/${INSTANCE}.conf"

if [[ -f "$FPM_POOL_FILE" ]]; then
  rm -f "$FPM_POOL_FILE"
  log "FPM pool slettet"
else
  log "FPM pool findes ikke"
fi

# Slet Unix-bruger
log "Sletter Unix-bruger"
if id "$INSTANCE" &>/dev/null; then
  # Stop alle bruger processer
  pkill -u "$INSTANCE" 2>/dev/null || true
  
  # Slet bruger
  if userdel -r "$INSTANCE" 2>/dev/null; then
    log "Bruger $INSTANCE slettet"
  else
    log "Kunne ikke slette bruger $INSTANCE"
  fi
else
  log "Bruger $INSTANCE findes ikke"
fi

# Slet chroot directory
log "Sletter chroot directory"
CHROOT_DIR="$CHROOT_BASE/$INSTANCE"

if [[ -d "$CHROOT_DIR" ]]; then
  if rm -rf "$CHROOT_DIR"; then
    log "Chroot directory slettet"
  else
    fail "Kunne ikke slette chroot directory"
  fi
else
  log "Chroot directory findes ikke"
fi

# Slet home directory (hvis den stadig findes)
if [[ -d "$USER_HOME" ]]; then
  if rm -rf "$USER_HOME"; then
    log "Home directory slettet"
  else
    fail "Kunne ikke slette home directory"
  fi
fi

# Slet Apache log files
log "Sletter Apache log files"
rm -f "/var/log/apache2/${INSTANCE}-error.log" "/var/log/apache2/${INSTANCE}-access.log"

# Slet PHP-FPM log
rm -f "/var/log/php8.2-fpm-$INSTANCE.log"

# Slet database (hvis den findes)
if [[ -n "${SELLYOURSAAS_DB_NAME:-}" ]]; then
  log "Sletter database: ${SELLYOURSAAS_DB_NAME}"
  
  sudo mysql -u root -p"${SELLYOURSAAS_DB_ROOT_PASSWORD:-}" <<EOF
DROP DATABASE IF EXISTS ${SELLYOURSAAS_DB_NAME};
DROP USER IF EXISTS '${INSTANCE}_dbuser'@'localhost';
FLUSH PRIVILEGES;
EOF
  
  log "Database slettet"
fi

# Genstart services
log "Genstarter Apache og PHP-FPM"
systemctl restart apache2 2>/dev/null || true
systemctl restart php8.2-fpm 2>/dev/null || true

log "Undeploy fuldført for $INSTANCE"
exit 0
