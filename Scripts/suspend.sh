#!/bin/bash
# SellYourSaaS action: suspend — skala-til-nul + blokeret Ingress, PVC bevaret
set -euo pipefail
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?}"
NS="tenant-${INSTANCE}"
kubectl -n "$NS" scale deploy --all --replicas=0
kubectl -n "$NS" scale sts --all --replicas=0
kubectl -n "$NS" patch ingress app -p '{"metadata":{"annotations":{"saasplatform.io/suspended":"true"}}}'
kubectl -n "$NS" delete cronjobs --all
echo "suspended $INSTANCE (pods skaleret til 0, PVC'er bevaret)"
