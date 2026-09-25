#!/bin/bash
# SellYourSaaS action: recreateauthorizedkeys — roter platformens adgang
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NS="tenant-${SELLYOURSAAS_INSTANCE_NAME:?}"
NEW=$(openssl rand -hex 32)
kubectl -n "$NS" create secret generic platform-access --from-literal=token="$NEW" --dry-run=client -o yaml | kubectl apply -f -
echo "rotated platform-access for ${SELLYOURSAAS_INSTANCE_NAME:?}"
