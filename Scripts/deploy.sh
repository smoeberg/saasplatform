#!/bin/bash
# SellYourSaaS action: deploy (også deployall via loop i master)
set -euo pipefail
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?}"
NS="tenant-${INSTANCE}"
CHART="${SAAS_CHART_DIR:?}/dolibarr"
VERSION="${SELLYOURSAAS_VERSION:?}"   # image-tag, styret af package-version

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: ResourceQuota
metadata: {name: default}
spec:
  hard: {requests.cpu: "2", requests.memory: 4Gi, limits.cpu: "4", limits.memory: 8Gi, persistentvolumeclaims: "3"}
YAML
kubectl -n "$NS" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
YAML
# (Tillad kun ingress-controller + DNS + egress til DB/mail efter behov — del af chartet)

helm upgrade --install "tenant" "$CHART" -n "$NS" \
  --set domain="${SELLYOURSAAS_DOLIBARRINSTANCE_URL##*://}" \
  --set image.tag="$VERSION" \
  --set instance="$INSTANCE" \
  --wait --timeout 10m

# Health: chartet eksponerer /healthz; agenten overvåger URL'en via cron.
echo "deployed $INSTANCE ($VERSION) -> https://${SELLYOURSAAS_DOLIBARRINSTANCE_URL##*://}"
