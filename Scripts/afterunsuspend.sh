#!/usr/bin/env bash
# afterunsuspend.sh — genopretter en suspenderet tenant til normal drift.

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

if ! release_exists; then
  fail "Kan ikke genoptage: release $RELEASE findes ikke"
fi

log "info" "Genopretter $RELEASE (skalerer op, genskaber CronJobs, retablerer Ingress)"
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=false \
  --wait --timeout 5m

wait_for_healthz "$(tenant_healthz_url)"

write_status "deployed"
log "info" "afterunsuspend fuldført for $RELEASE"
