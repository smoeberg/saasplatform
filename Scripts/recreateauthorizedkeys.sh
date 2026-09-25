#!/usr/bin/env bash
# recreateauthorizedkeys.sh — SellYourSaaS action: roter platformens adgang

source "$(dirname "$0")/lib.sh" "$@"

# Generer ny adgangstoken
NEW_TOKEN=$(openssl rand -hex 32)

# Opret som SealedSecret
create_sealed_secret "platform-access" "$NAMESPACE" \
  token="$NEW_TOKEN"

log "info" "Roteret platform-access secret for $INSTANCE"
