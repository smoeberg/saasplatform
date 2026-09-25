#!/usr/bin/env bash
# undeploy.sh — SellYourSaaS action: permanent nedlæggelse

source "$(dirname "$0")/lib.sh" "$@"

if release_exists; then
  log "info" "Tager sikkerheds-DB-dump før undeploy"
  source "$(dirname "$0")/beforeundeploy.sh" "$INSTANCE"
  
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

# Slet DNS-record
dns_delete "$NAMESPACE"

rm -f "$VALUES_FILE"
write_status "undeployed"

log "info" "undeploy fuldført for $RELEASE"
