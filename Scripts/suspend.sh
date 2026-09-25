#!/bin/bash
# SellYourSaaS action: suspend — skala-til-nul + blokeret Ingress, PVC bevaret
set -euo pipefail
source "$(dirname "$0")/lib.sh"
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?}"
NS="$(resolve_namespace)"
kubectl -n "$NS" scale deploy --all --replicas=0
kubectl -n "$NS" scale sts --all --replicas=0
kubectl -n "$NS" patch ingress app -p '{"metadata":{"annotations":{"saasplatform.io/suspended":"true"}}}'
kubectl -n "$NS" delete cronjobs --all
echo "suspended $INSTANCE (pods skaleret til 0, PVC'er bevaret)"
