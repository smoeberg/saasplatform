#!/usr/bin/env bash
# refresh.sh — Re-konvergerer tenanten til den tilstand values-filen beskriver.
# Bruges også ved version-opdatering og rollback (§3.5).

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

if ! release_exists; then
  fail "Kan ikke refreshe: release $RELEASE findes ikke — kør afterdeploy først"
fi

log "info" "Re-konvergerer $RELEASE mod $VALUES_FILE"
# --atomic ruller K8s-ressourcerne tilbage automatisk hvis upgraden fejler undervejs.
# OBS: det dækker ikke en DB-migrering der allerede nåede at køre inde i containeren
# før fejlen — se noten om skema-rollback for Dolibarr-tenants i arkitekturdokumentet.
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --wait --timeout 5m \
  --atomic

wait_for_healthz "$(tenant_healthz_url)"

write_status "deployed"
log "info" "refresh fuldført for $RELEASE"
