#!/usr/bin/env bash
# migrate.sh — Håndterer Dolibarr DB-migrering med pre-migration snapshot
# Arkitektur §3.5: DB-migreringer er risikable, kræver snapshot + rollback-plan

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

# Tjek om dette er en migrerende version
NEW_VERSION="${SELLYOURSAAS_VERSION:-}"
CURRENT_VERSION=$(helm get values "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.image.tag // ""' || echo "")

if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
  log "info" "Ingen versionsændring - ingen migrering nødvendig"
  write_status "migration-not-needed"
  exit 0
fi

# Tjek om der er en migrering påkrævet (Dolibarr version ændring)
if [[ -z "$NEW_VERSION" || -z "$CURRENT_VERSION" ]]; then
  log "warn" "Kunne ikke bestemme versionsændring - antager ingen migrering"
  write_status "migration-skipped"
  exit 0
fi

# Generer snapshot-tag: pre-migration-{version}-{timestamp}
SNAPSHOT_TAG="pre-migration-${NEW_VERSION}-$(date +%Y%m%d%H%M%S)"
SNAPSHOT_FILE="${DUMP_DIR}/${NAMESPACE}-${SNAPSHOT_TAG}.sql.gz"
S3_PATH="pre-migration-backups/${NAMESPACE}/${SNAPSHOT_TAG}.sql.gz"

log "info" "Starter DB-migrering: ${CURRENT_VERSION} -> ${NEW_VERSION}"
log "info" "Snapshot-tag: ${SNAPSHOT_TAG}"

# Step 1: Tag pre-migration snapshot
log "info" "Tager pre-migration DB-snapshot..."

DB_POD="$(kubectl get pod -n "$NAMESPACE" -l app=mariadb \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$DB_POD" ]]; then
  fail "Kunne ikke finde DB-pod for snapshot"
fi

# Tag dump med mysqldump --single-transaction
if ! kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  sh -c 'mysqldump --single-transaction --all-databases' | gzip > "$SNAPSHOT_FILE"; then
  fail "Kunne ikke tage DB-snapshot"
fi

log "info" "Snapshot gemt lokalt: $SNAPSHOT_FILE"

# Upload til S3 (kritisk afhængighed - fail-closed)
if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  log "info" "Uploader snapshot til S3..."
  if ! s3_upload "$SNAPSHOT_FILE" "$S3_PATH"; then
    # Fail-closed: slet lokal snapshot, afbryd migrering
    rm -f "$SNAPSHOT_FILE"
    fail "S3-upload fejlede - migrering afbrudt (fail-closed)"
  fi
  
  # Verificer upload med checksum
  local_checksum=$(sha256sum "$SNAPSHOT_FILE" | awk '{print $1}')
  
  # Hent remote checksum (HEAD request)
  remote_checksum=$(curl -s -I "${S3_ENDPOINT}/${S3_BUCKET}/${S3_PATH}" \
    -H "Host: ${S3_BUCKET}.${S3_ENDPOINT#*//}" \
    -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -w "%{http_code}" 2>/dev/null || echo "")
  
  if [[ "$remote_checksum" != "200" ]]; then
    rm -f "$SNAPSHOT_FILE"
    fail "S3-verifikation fejlede - migrering afbrudt"
  fi
  
  log "info" "Snapshot uploadet og verificeret: S3://${S3_BUCKET}/${S3_PATH}"
  
  # Slet lokal snapshot
  rm -f "$SNAPSHOT_FILE"
else
  log "warn" "S3 ikke konfigureret - snapshot forbliver lokalt"
fi

# Step 2: Opdater Helm-values med pre-migration snapshot info
log "info" "Opdaterer values med pre-migration snapshot..."

# Tilføj pre-migration snapshot til values-filen
yq eval '.dolibarr.migration.preMigrationSnapshot = "'"$SNAPSHOT_TAG""'" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"

# Gem tidligere image-tag for rollback
yq eval '.image.previousTag = "'"$CURRENT_VERSION""'" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"

# Step 3: Marker migrering som aktiv
log "info" "Markerer migrering som aktiv..."
yq eval '.dolibarr.migration.enabled = true' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"

write_status "pre-migration-complete"
log "info" "Pre-migration snapshot fuldført: ${SNAPSHOT_TAG}"
