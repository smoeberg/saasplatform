#!/usr/bin/env bash
# afterundeploy.sh — permanent nedlæggelse af tenant. Idempotent: fejler ikke hvis
# release/namespace allerede er væk, så scriptet trygt kan genkøres (§3.7).

source "$(dirname "$0")/lib.sh" "$@"

if release_exists; then
  log "info" "Afinstallerer helm-release $RELEASE"
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 5m
else
  log "warn" "Release $RELEASE findes ikke — springer helm uninstall over"
fi

if namespace_exists; then
  log "info" "Sletter namespace $NAMESPACE"
  kubectl delete namespace "$NAMESPACE" --wait --timeout=5m
else
  log "warn" "Namespace $NAMESPACE findes ikke — springer sletning over"
fi

rm -f "$VALUES_FILE"
write_status "undeployed"

log "info" "afterundeploy fuldført for $RELEASE"
