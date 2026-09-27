#!/usr/bin/env bash
# beforeundeploy.sh — Sikkerhedsnet før permanent nedlæggelse: 
# tager DB-dump og uploader til S3 (Wasabi)

source "$(dirname "$0")/lib.sh" "$@"

if ! release_exists; then
  log "warn" "Release $RELEASE findes ikke — intet at sikkerhedskopiere, fortsætter"
  write_status "preundeploy-backup-ok"
  exit 0
fi

DUMP_FILE="${DUMP_DIR}/${NAMESPACE}-$(date +%Y%m%d%H%M%S).sql.gz"

# Find DB-pod (MariaDB) - bruger det nye label fra erp-tenant chartet
DB_POD="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=db \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$DB_POD" ]]; then
  log "warn" "Fandt ingen DB-pod i $NAMESPACE (label app=mariadb) — springer dump over"
  write_status "preundeploy-backup-skipped"
  exit 0
fi

log "info" "Dumper DB fra $DB_POD til $DUMP_FILE"

# Haent DB credentials fra SealedSecret/Secret
DB_USER=$(kubectl get secret -n "$NAMESPACE" tenant-db -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo "")
DB_PASSWORD=$(kubectl get secret -n "$NAMESPACE" tenant-db -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "")

if [[ -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
  log "err" "Kunne ikke hente DB credentials fra tenant-db secret i $NAMESPACE"
  write_status "preundeploy-backup-failed"
  exit 1
fi

# Tag dump med mysqldump --single-transaction for InnoDB-konsistens
kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  sh -c "mysqldump --single-transaction --all-databases -u '$DB_USER' -p'$DB_PASSWORD'" | gzip > "$DUMP_FILE"

log "info" "DB-dump gemt lokalt: $DUMP_FILE"

# Upload til S3 (Wasabi)
if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  log "info" "Uploader dump til S3"
  s3_upload "$DUMP_FILE" "backups/${NAMESPACE}/$(basename "$DUMP_FILE")"
  
  # Slet lokal dump efter vellykket upload
  rm -f "$DUMP_FILE"
  log "info" "Lokal dump slettet efter S3-upload"
else
  log "warn" "S3 ikke konfigureret — dump forbliver lokalt: $DUMP_FILE"
fi

write_status "preundeploy-backup-ok"
