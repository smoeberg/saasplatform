#!/bin/bash
# SellYourSaaS action: unsuspend
set -euo pipefail
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?}"
NS="tenant-${INSTANCE}"
kubectl -n "$NS" patch ingress app --type merge -p '{"metadata":{"annotations":{"saasplatform.io/suspended":null}}}'
helm upgrade --install tenant "${SAAS_CHART_DIR:?}/dolibarr" -n "$NS" --reuse-values --wait
echo "unsuspended $INSTANCE"
