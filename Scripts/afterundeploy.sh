#!/usr/bin/env bash
# afterundeploy.sh - SellYourSaaS action: afterundeploy
# Cleanup after tenant undeployment

source "$(dirname "$0")/lib.sh" "$@"

# Acquire lock to prevent parallel operations on same tenant
acquire_lock

require_values_file

if ! release_exists; then
  log "warn" "Release $RELEASE findes ikke - intet at gore"
  rm -f "$VALUES_FILE"
  write_status "undeployed"
  exit 0
fi

log "info" "Fjerner Helm release $RELEASE"
helm uninstall "$RELEASE" -n "$NAMESPACE" || true

log "info" "Fjerner namespace $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --wait=false || true

# Slet values-fil
rm -f "$VALUES_FILE"

# Slet DNS-record
dns_delete "$NAMESPACE"

write_status "undeployed"
log "info" "afterundeploy fuldfort for $RELEASE"
