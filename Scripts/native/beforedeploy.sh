#!/usr/bin/env bash
# beforedeploy.sh - SellYourSaaS native pre-flight check
# Validerer at systemet er klar til at deploye en ny tenant

set -euo pipefail

# Konfiguration
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:-}"

# Logging
log() {
  echo "[$(date -Is)] [beforedeploy] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Tjek at vi har tilstrkkelige rettigheder
if [[ $EUID -ne 0 ]]; then
  fail "Skal kres som root"
fi

# Tjek at Apache krer
if ! systemctl is-active --quiet apache2; then
  fail "Apache krer ikke"
fi

log "Apache krer"

# Tjek at PHP-FPM krer
if ! systemctl is-active --quiet php8.2-fpm; then
  fail "PHP-FPM krer ikke"
fi

log "PHP-FPM krer"

# Tjek at ndvendige mapper findes
for dir in /etc/apache2/sites-available /etc/apache2/sites-enabled /etc/php/8.2/fpm/pool.d /var/www/chroot; do
  if [[ ! -d "$dir" ]]; then
    fail "Mappe $dir findes ikke"
  fi
done

log "Alle ndvendige mapper findes"

# Tjek at brugeren ikke allerede findes (for ny deploy)
if [[ -n "$INSTANCE" && "$INSTANCE" != "test" ]]; then
  if id "$INSTANCE" &>/dev/null; then
    log "Bruger $INSTANCE findes allerede - antager gen-deploy"
  fi
fi

# Tjek at der er ledig diskplads
DISK_AVAILABLE=$(df / --output=avail -k | tail -1)
if [[ $DISK_AVAILABLE -lt 1048576 ]]; then  # < 1GB
  fail "Utilstrkkelig diskplads (mindst 1GB krvet)"
fi

log "Diskplads OK"

# Tjek at der er ledig memory
MEM_AVAILABLE=$(free -m | awk '/Mem:/ {print $4}')
if [[ $MEM_AVAILABLE -lt 512 ]]; then  # < 512MB
  fail "Utilstrkkelig memory (mindst 512MB krvet)"
fi

log "Memory OK"

log "Pre-flight check bestet"
exit 0
