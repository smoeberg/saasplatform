#!/usr/bin/env bash
# aftersuspend.sh - SellYourSaaS action: aftersuspend
# Suspend tenant via Helm

source "$(dirname "$0")/lib.sh" "$@"

# Acquire lock to prevent parallel operations on same tenant
acquire_lock

require_values_file

if ! release_exists; then
  fail "Kan ikke suspendere: release $RELEASE findes ikke"
fi

log "info" "Suspenderer $RELEASE (saetter suspended=true, sletter CronJobs)"

# Slet alle CronJobs i namespace (ifolge arkitektur 3.3: CronJobs slettes, ikke skaleres)
kubectl delete cronjob --all -n "$NAMESPACE" --ignore-not-found=true || true

helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=true \
  --wait --timeout 3m

write_status "suspended"
log "info" "aftersuspend fuldfort for $RELEASE"
