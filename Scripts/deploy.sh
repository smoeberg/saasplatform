#!/usr/bin/env bash
# deploy.sh — SellYourSaaS action: deploy
# Arkitektur §3.3.1 (mapping+secrets), §5 fase 1b (DNS)

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

log "info" "Opretter namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Opret DB-secrets som SealedSecret
log "info" "Opretter DB-secrets"
create_sealed_secret "tenant-db" "$NAMESPACE" \
  username=$(openssl rand -hex 16) \
  password=$(openssl rand -hex 32) \
  root_password=$(openssl rand -hex 32)

log "info" "Kører helm upgrade --install for $RELEASE i $NAMESPACE"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES_FILE" \
  --set domain="${SELLYOURSAAS_DOLIBARRINSTANCE_URL##*://}" \
  --set image.tag="${SELLYOURSAAS_VERSION:-latest}" \
  --set instance="$INSTANCE" \
  --set suspended=false \
  --wait --timeout 10m \
  --atomic

# Opret DNS-record
dns_create "$NAMESPACE"

wait_for_healthz "$(tenant_healthz_url)"

write_status "deployed"
log "info" "deploy fuldført for $RELEASE -> ${SELLYOURSAAS_DOLIBARRINSTANCE_URL}"
