#!/bin/bash
# SellYourSaaS action: undeploy — backup-dump først, derefter sletning
set -euo pipefail
INSTANCE="${SELLYOURSAAS_INSTANCE_NAME:?}"
NS="tenant-${INSTANCE}"

# 1. Ekstern DB-dump til S3 (pr. tenant)
kubectl -n "$NS" create job --from=cronjob/db-dump "final-dump-$(date +%s)" && kubectl -n "$NS" wait --for=condition=complete job/final-dump-$(date +%s) --timeout=15m || true
# 2. Helm-uninstall
helm uninstall tenant -n "$NS" || true
# 3. Namespace-sletning (PVC'er følger med, backup findes eksternt)
kubectl delete namespace "$NS" --wait=false
# 4. Revoke: platformens serviceadgang til tenanten findes ikke længere (namespace væk)
echo "undeployed $INSTANCE (backup Dump + S3 før sletning)"
