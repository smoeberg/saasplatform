#!/bin/bash
# SellYourSaaS action: deploy (også deployall via loop i master)
# Arkitektur §3.3.1 (mapping+secrets), §5 fase 1b (DNS)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

NS="$(resolve_namespace)"
CHART="${SAAS_CHART_DIR:?}/dolibarr"
VERSION="${SELLYOURSAAS_VERSION:?}"   # image-tag = package-version (Arkitektur §3.5)

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# ResourceQuota + NetworkPolicy ejes af chartet (default-deny + allow-regler) — ikke her
ensure_secrets "$NS"

helm upgrade --install "tenant" "$CHART" -n "$NS" \
  --set domain="${SELLYOURSAAS_DOLIBARRINSTANCE_URL##*://}" \
  --set image.tag="$VERSION" \
  --set instance="$NS" \
  --wait --timeout 10m

dns_create "$NS"   # opret DNS før health-check

# Health: chartet eksponerer /healthz; agenten overvåger URL'en via cron.
log "deployed $NS ($VERSION) -> ${SELLYOURSAAS_DOLIBARRINSTANCE_URL}"
