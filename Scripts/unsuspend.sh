#!/usr/bin/env bash
# unsuspend.sh — SellYourSaaS action: genoptager tenant

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

if ! release_exists; then
  fail "Kan ikke genoptage: release $RELEASE findes ikke"
fi

log "info" "Genoptager $RELEASE (sætter suspended=false)"
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=false \
  --wait --timeout 5m

wait_for_healthz "$(tenant_healthz_url)"

write_status "deployed"
log "info" "unsuspend fuldført for $RELEASE"
