#!/bin/bash
# SellYourSaaS action: unsuspend
set -euo pipefail
source "$(dirname "$0")/lib.sh"
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?}"
NS="$(resolve_namespace)"
kubectl -n "$NS" patch ingress app --type merge -p '{"metadata":{"annotations":{"saasplatform.io/suspended":null}}}'
helm upgrade --install tenant "${SAAS_CHART_DIR:?}/dolibarr" -n "$NS" --reuse-values --wait
echo "unsuspended $INSTANCE"
