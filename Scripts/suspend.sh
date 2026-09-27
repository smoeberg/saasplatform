#!/usr/bin/env bash
# suspend.sh — SellYourSaaS action: suspender tenant

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

if ! release_exists; then
  fail "Kan ikke suspendere: release $RELEASE findes ikke"
fi

log "info" "Suspenderer $RELEASE (sætter suspended=true, sletter CronJobs)"

# Slet alle CronJobs i namespace (ifølge arkitektur §3.3: CronJobs slettes, ikke skaleres)
kubectl delete cronjob --all -n "$NAMESPACE" --ignore-not-found=true || true

helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=true \
  --wait --timeout 3m

write_status "suspended"
log "info" "suspend fuldført for $RELEASE"
