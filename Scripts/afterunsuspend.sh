#!/usr/bin/env bash
# afterunsuspend.sh - SellYourSaaS action: afterunsuspend
# Unsuspend tenant via Helm

source "$(dirname "$0")/lib.sh" "$@"

# Acquire lock to prevent parallel operations on same tenant
acquire_lock

require_values_file

if ! release_exists; then
  fail "Kan ikke genoptage: release $RELEASE findes ikke"
fi

log "info" "Genoptager $RELEASE (saetter suspended=false, genskaber CronJobs via Helm)"

helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=false \
  --wait --timeout 5m

# Helm vil genskabe CronJobs fra chartet (deklarativt)
log "info" "CronJobs genskabt via Helm upgrade"

wait_for_healthz "$(tenant_healthz_url)"

write_status "deployed"
log "info" "afterunsuspend fuldfort for $RELEASE"
