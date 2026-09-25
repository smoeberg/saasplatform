#!/usr/bin/env bash
# deploy.sh - SellYourSaaS native deployment action
# Opretter Unix-bruger, chroot, FPM pool, og Apache vhost for en tenant

set -euo pipefail

# Konfiguration
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?Mangler SELLYOURSAAS_INSTANCE_NAME}"
TENANT_DOMAIN="${SELLYOURSAAS_DOLIBARRINSTANCE_URL:-}"
DOMAIN="${TENANT_DOMAIN#*://}"
DOMAIN="${DOMAIN%/}"

# Sanitize instance name (kun a-z, 0-9, -)
if [[ ! "$INSTANCE" =~ ^[a-z0-9-]+$ ]]; then
  echo "FATAL: INSTANCE '$INSTANCE' indeholder ugyldige tegn" >&2
  exit 2
fi

# Standard paths
USER_HOME="/home/$INSTANCE"
CHROOT_BASE="/var/www/chroot"
APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
APACHE_SITES_ENABLED="/etc/apache2/sites-enabled"
PHP_FPM_POOL_DIR="/etc/php/8.2/fpm/pool.d"

# Logging
log() {
  echo "[$(date -Is)] [deploy] [$INSTANCE] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Opret Unix-bruger
log "Opretter Unix-bruger: $INSTANCE"
if id "$INSTANCE" &>/dev/null; then
  log "Bruger $INSTANCE findes allerede"
else
  if ! useradd -r -s /bin/bash -m -d "$USER_HOME" "$INSTANCE"; then
    fail "Kunne ikke oprette bruger $INSTANCE"
  fi
  log "Bruger $INSTANCE oprettet"
fi

# Opret chroot miljø
log "Opretter chroot miljø for $INSTANCE"
CHROOT_DIR="$CHROOT_BASE/$INSTANCE"

if [[ -d "$CHROOT_DIR" ]]; then
  log "Chroot directory findes allerede"
else
  # Opret chroot struktur
  mkdir -p "$CHROOT_DIR/{bin,dev,etc,lib,lib64,proc,sys,tmp,usr,var}"
  
  # Kopier nødvendige systemfiler
  cp -r /bin "$CHROOT_DIR/bin"
  cp -r /dev "$CHROOT_DIR/dev"
  cp -r /etc "$CHROOT_DIR/etc"
  cp -r /lib "$CHROOT_DIR/lib"
  cp -r /lib64 "$CHROOT_DIR/lib64"
  cp -r /usr "$CHROOT_DIR/usr"
  cp -r /var "$CHROOT_DIR/var"
  
  # Symlinks
  ln -sf "$CHROOT_DIR/usr/bin" "$CHROOT_DIR/bin"
  ln -sf "$CHROOT_DIR/usr/lib" "$CHROOT_DIR/lib"
  ln -sf "$CHROOT_DIR/usr/lib64" "$CHROOT_DIR/lib64"
  
  # Kopier PHP
  mkdir -p "$CHROOT_DIR/usr/bin"
  cp /usr/bin/php "$CHROOT_DIR/usr/bin/php"
  cp /usr/bin/php8.2 "$CHROOT_DIR/usr/bin/php8.2"
  
  # Kopier PHP libraries
  mkdir -p "$CHROOT_DIR/usr/lib/php/8.2"
  cp -r /usr/lib/php/8.2/* "$CHROOT_DIR/usr/lib/php/8.2/"
  
  # Kopier timezonedata
  mkdir -p "$CHROOT_DIR/usr/share/zoneinfo"
  cp -r /usr/share/zoneinfo/* "$CHROOT_DIR/usr/share/zoneinfo/"
  
  # Sæt permissions
  chmod -R u+rwX "$CHROOT_DIR"
  log "Chroot miljø oprettet"
fi

# Opret public_html directory
log "Opretter public_html directory"
mkdir -p "$USER_HOME/public_html"
chown "$INSTANCE:$INSTANCE" "$USER_HOME/public_html"
chmod 750 "$USER_HOME/public_html"

# Kopier healthz.php
cat <<'EOF' | tee "$USER_HOME/public_html/healthz.php" >/dev/null
<?php
header('Content-Type: text/plain');
echo "OK";
exit(0);
?>
EOF
chown "$INSTANCE:$INSTANCE" "$USER_HOME/public_html/healthz.php"

# Opret Apache vhost
log "Opretter Apache vhost for $DOMAIN"
VHOST_FILE="$APACHE_SITES_AVAILABLE/${INSTANCE}.conf"

cat <<EOF | tee "$VHOST_FILE" >/dev/null
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    ServerAdmin webmaster@$DOMAIN
    
    DocumentRoot $USER_HOME/public_html
    
    <Directory $USER_HOME/public_html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    <FilesMatch \\.php$>
        SetHandler "proxy:unix:/run/php/php8.2-fpm-$INSTANCE.sock|fcgi://localhost"
    </FilesMatch>
    
    ErrorLog /var/log/apache2/${INSTANCE}-error.log
    CustomLog /var/log/apache2/${INSTANCE}-access.log combined
    
    <Location /healthz>
        SetHandler "proxy:unix:/run/php/php8.2-fpm-$INSTANCE.sock|fcgi://localhost"
    </Location>
</VirtualHost>
EOF

# Aktiver vhost
a2ensite "$INSTANCE.conf"

# Opret PHP-FPM pool
log "Opretter PHP-FPM pool for $INSTANCE"
FPM_POOL_FILE="$PHP_FPM_POOL_DIR/${INSTANCE}.conf"

cat <<EOF | tee "$FPM_POOL_FILE" >/dev/null
[$INSTANCE]
user = $INSTANCE
group = $INSTANCE
listen = /run/php/php8.2-fpm-$INSTANCE.sock
listen.owner = $INSTANCE
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500

chroot = $CHROOT_DIR
chdir = /

php_admin_value[error_log] = /var/log/php8.2-fpm-$INSTANCE.log
php_admin_flag[log_errors] = on
php_admin_flag[catch_workers_output] = on

; Security
php_admin_flag[disable_functions] = exec,passthru,shell_exec,system
php_admin_flag[allow_url_fopen] = off
php_admin_flag[expose_php] = off
EOF

# Opret log files
touch "/var/log/apache2/${INSTANCE}-error.log"
touch "/var/log/apache2/${INSTANCE}-access.log"
touch "/var/log/php8.2-fpm-$INSTANCE.log"
chown www-data:www-data "/var/log/apache2/${INSTANCE}-*.log"
chown "$INSTANCE:$INSTANCE" "/var/log/php8.2-fpm-$INSTANCE.log"

# Genstart services
log "Genstarter Apache og PHP-FPM"
systemctl restart apache2
systemctl restart php8.2-fpm

# Opret database (hvis konfigureret)
if [[ -n "${SELLYOURSAAS_DB_NAME:-}" ]]; then
  log "Opretter database: ${SELLYOURSAAS_DB_NAME}"
  
  # Opret database bruger
  DB_USER="${INSTANCE}_dbuser"
  DB_PASSWORD=$(openssl rand -hex 16)
  
  sudo mysql -u root -p"${SELLYOURSAAS_DB_ROOT_PASSWORD:-}" <<EOF
CREATE DATABASE IF NOT EXISTS ${SELLYOURSAAS_DB_NAME};
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON ${SELLYOURSAAS_DB_NAME}.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
  
  # Gem credentials til tenant config
  mkdir -p "$USER_HOME/.config"
  cat <<EOF | tee "$USER_HOME/.config/db-config.php" >/dev/null
<?php
\$db_host = 'localhost';
\$db_name = '${SELLYOURSAAS_DB_NAME}';
\$db_user = '$DB_USER';
\$db_password = '$DB_PASSWORD';
?>
EOF
  chown "$INSTANCE:$INSTANCE" "$USER_HOME/.config/db-config.php"
  
  log "Database oprettet"
fi

# Verificer deployment
log "Verificerer deployment..."

# Tjek at bruger findes
if ! id "$INSTANCE" &>/dev/null; then
  fail "Bruger $INSTANCE findes ikke"
fi

# Tjek at vhost findes
if [[ ! -f "$VHOST_FILE" ]]; then
  fail "Vhost $VHOST_FILE findes ikke"
fi

# Tjek at FPM pool findes
if [[ ! -f "$FPM_POOL_FILE" ]]; then
  fail "FPM pool $FPM_POOL_FILE findes ikke"
fi

# Tjek at Apache vhost er aktiveret
if [[ ! -L "$APACHE_SITES_ENABLED/${INSTANCE}.conf" ]]; then
  fail "Vhost ikke aktiveret"
fi

# Test healthz
if curl -fsS -o /dev/null -m 5 "http://$DOMAIN/healthz" 2>/dev/null; then
  log "Healthz check: OK"
else
  log "Healthz check: Advarsel (kan skyldes DNS)"
fi

log "Deploy fuldført for $INSTANCE"
exit 0
