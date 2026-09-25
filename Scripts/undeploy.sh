#!/bin/bash
# SellYourSaaS action: undeploy — slet tenant efter retention (Arkitektur §3.3)
# Rækkefølge: DB-dump → helm uninstall → DNS → namespace (inkl. PVC) → extrafield slettes
set -euo pipefail
source "$(dirname "$0")/lib.sh"

NS="$(resolve_namespace)"

# 1. Fail-closed: sikkerhedskopi af DB før sletning
if kubectl -n "$NS" get pod mariadb-0 >/dev/null 2>&1; then
  log "tager endeligt DB-dump før sletning"
  kubectl -n "$NS" exec mariadb-0 -- mariadb-dump -u root \
    -p"$(kubectl -n "$NS" get secret tenant-db -o jsonpath='{.data.root_password}' | base64 -d)" \
    --single-transaction dolibarr > "/tmp/backup-${NS}-$(date -u +%FT%TZ).sql"
  # upload til S3 (Wasabi) — afbryd ved fejl, slet ikke tenant ved manglende backup
  aws s3 cp "/tmp/backup-${NS}-$(date -u +%FT%TZ).sql" "s3://${SAAS_BACKUP_BUCKET}/${NS}/final-$(date -u +%FT%TZ).sql" \
    --endpoint-url "${SAAS_S3_ENDPOINT:-https://s3.eu-central-1.wasabisys.com}" \
    || fail "kunne ikke uploade endeligt dump — sletning afbrudt (fail-closed)"
  rm -f "/tmp/backup-${NS}-$(date -u +%FT%TZ).sql"
fi

# 2. helm uninstall
helm uninstall tenant -n "$NS" || log "helm-release findes ikke"

# 3. DNS slettes
dns_delete

# 4. Namespace (inkl. PVC'er) slettes
kubectl delete namespace "$NS" --wait

# 5. Extrafield k8s_namespace/helm_release ryddes, så kontrakten kan genbruges (Arkitektur §3.3.1)
set_extrafield k8s_namespace ""
set_extrafield helm_release ""
log "undeployed $NS"
