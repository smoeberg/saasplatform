#!/usr/bin/env bash
# afterdeploy.sh — udruller tenant via Helm og efterlader et statusartefakt som
# SellYourSaaS-agenten kan læse for at registrere instansen som "deployed" (§3.2).

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

log "info" "Kører helm upgrade --install for $RELEASE i $NAMESPACE"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES_FILE" \
  --set suspended=false \
  --wait --timeout 5m \
  --atomic

wait_for_healthz "$(tenant_healthz_url)"

# ANTAGELSE: formatet af dette statusartefakt er ikke verificeret mod SellYourSaaS'
# faktiske "deployed"-kontrakt endnu — match det, når I kender den nøjagtige mekanisme
# agenten selv kigger efter (se README.md, punkt "Åbent").
write_status "deployed"
kubectl get pods -n "$NAMESPACE" -o wide

log "info" "afterdeploy fuldført for $RELEASE"
