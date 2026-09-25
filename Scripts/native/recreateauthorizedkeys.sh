#!/usr/bin/env bash
# recreateauthorizedkeys.sh - SellYourSaaS native recreateauthorizedkeys action
# Roterer SSH-keys for en tenant

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
SSH_DIR="$USER_HOME/.ssh"

# Logging
log() {
  echo "[$(date -Is)] [recreateauthorizedkeys] [$INSTANCE] $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Tjek at bruger findes
if ! id "$INSTANCE" &>/dev/null; then
  fail "Bruger $INSTANCE findes ikke"
fi

# Opret .ssh directory
log "Opretter .ssh directory"
mkdir -p "$SSH_DIR"
chown "$INSTANCE:$INSTANCE" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generer nye SSH-keys
log "Genererer nye SSH-keys"
NEW_KEY_FILE="$SSH_DIR/id_rsa"
NEW_PUB_FILE="$SSH_DIR/id_rsa.pub"

if ssh-keygen -t rsa -b 4096 -f "$NEW_KEY_FILE" -N "" -C "$INSTANCE@saasplatform.dk" 2>/dev/null; then
  log "Nye SSH-keys genereret"
else
  fail "Kunne ikke generere SSH-keys"
fi

# St korrekte permissions
chown "$INSTANCE:$INSTANCE" "$NEW_KEY_FILE" "$NEW_PUB_FILE"
chmod 600 "$NEW_KEY_FILE"
chmod 644 "$NEW_PUB_FILE"

# Slet gamle keys (hvis de findes)
rm -f "$SSH_DIR/id_*.old" "$SSH_DIR/id_*.pub.old"

# Opret authorized_keys (til selv-adgang)
log "Opretter authorized_keys"
cat "$NEW_PUB_FILE" > "$SSH_DIR/authorized_keys"
chown "$INSTANCE:$INSTANCE" "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"

# Konfigurer SSH for chroot (valgfrit)
if [[ -d "/var/www/chroot/$INSTANCE" ]]; then
  log "Konfigurerer SSH for chroot"
  
  # Opret .ssh i chroot
  CHROOT_SSH_DIR="/var/www/chroot/$INSTANCE/home/$INSTANCE/.ssh"
  mkdir -p "$CHROOT_SSH_DIR"
  cp "$NEW_KEY_FILE" "$CHROOT_SSH_DIR/id_rsa"
  cp "$NEW_PUB_FILE" "$CHROOT_SSH_DIR/id_rsa.pub"
  cp "$SSH_DIR/authorized_keys" "$CHROOT_SSH_DIR/authorized_keys"
  chown -R "$INSTANCE:$INSTANCE" "$CHROOT_SSH_DIR"
  chmod 700 "$CHROOT_SSH_DIR"
  chmod 600 "$CHROOT_SSH_DIR/id_rsa" "$CHROOT_SSH_DIR/authorized_keys"
  chmod 644 "$CHROOT_SSH_DIR/id_rsa.pub"
fi

log "SSH-keys roteret for $INSTANCE"
exit 0
