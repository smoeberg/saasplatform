#!/usr/bin/env bash
# aftersuspend.sh — suspenderer tenant deklarativt via Helm (§3.3): PVC'er bevares,
# CronJobs slettes (genskabes ved unsuspend), Ingress skifter til "suspended"-tilstand.
# Kræver at Helm-charten forstår .Values.suspended — byg den flag ind i charten
# (namespace/erp-tenant), ikke som separate kubectl scale-kald her, så tilstanden
# forbliver ét sted (Helm) i stedet for to.

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

if ! release_exists; then
  fail "Kan ikke suspendere: release $RELEASE findes ikke"
fi

log "info" "Suspenderer $RELEASE (skalerer til 0, fjerner CronJobs, skifter Ingress)"
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=true \
  --wait --timeout 3m

write_status "suspended"
log "info" "aftersuspend fuldført for $RELEASE"
