#!/usr/bin/env bash
# refresh.sh - SellYourSaaS action: refresh
# Re-apply state (re-konvergering)

source "$(dirname "$0")/lib.sh" "$@"

# Acquire lock to prevent parallel operations on same tenant
acquire_lock

require_values_file

if ! release_exists; then
  log "warn" "Release $RELEASE findes ikke - intet at refreshe"
  exit 0
fi

log "info" "Re-applier Helm chart for $RELEASE"
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --wait --timeout 5m

write_status "deployed"
log "info" "refresh fuldfort for $RELEASE"
