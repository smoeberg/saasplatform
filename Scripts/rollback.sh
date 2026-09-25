#!/usr/bin/env bash
# rollback.sh — Gendan tenant til tidligere version efter fejlet migrering
# Arkitektur §3.5: DB-migreringer kræver rollback-procedure
# 
# Rollback-procedure (fra arkitekturdokumentet):
# 1. Opret frisk namespace + helm-install med ingen data (pods stoppet)
# 2. Indlæs DB-dump (seneste konsistente punkt)
# 3. Velero-restore af PVC (documents)
# 4. Start pods; verificér /healthz + login

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

# Læs rollback-indstillinger fra values
ROLLBACK_ENABLED=$(yq eval '.rollback.enabled // false' "$VALUES_FILE")
TARGET_VERSION=$(yq eval '.rollback.targetVersion // ""' "$VALUES_FILE")
RESTORE_SNAPSHOT=$(yq eval '.rollback.restoreFromSnapshot // ""' "$VALUES_FILE")

if [[ "$ROLLBACK_ENABLED" != "true" ]]; then
  log "info" "Rollback ikke aktiveret - intet at gøre"
  write_status "rollback-not-needed"
  exit 0
fi

if [[ -z "$TARGET_VERSION" ]]; then
  fail "Rollback kræver targetVersion"
fi

if [[ -z "$RESTORE_SNAPSHOT" ]]; then
  # Prøv at finde seneste pre-migration snapshot
  RESTORE_SNAPSHOT=$(yq eval '.dolibarr.migration.preMigrationSnapshot // ""' "$VALUES_FILE")
  if [[ -z "$RESTORE_SNAPSHOT" ]]; then
    fail "Ingen snapshot specificeret for rollback"
  fi
fi

log "info" "Starter rollback til version: ${TARGET_VERSION}"
log "info" "Restore fra snapshot: ${RESTORE_SNAPSHOT}"

# Step 1: Undeploy nuværende version (bevar namespace for nu)
log "info" "Afinstallerer nuværende release..."
if release_exists; then
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 5m
fi

# Step 2: Hent pre-migration snapshot fra S3
S3_PATH="pre-migration-backups/${NAMESPACE}/${RESTORE_SNAPSHOT}.sql.gz"
LOCAL_DUMP="${DUMP_DIR}/${RESTORE_SNAPSHOT}.sql.gz"

log "info" "Henter snapshot fra S3: ${S3_PATH}"

# Download fra S3
if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  curl -s -X GET "${S3_ENDPOINT}/${S3_BUCKET}/${S3_PATH}" \
    -H "Host: ${S3_BUCKET}.${S3_ENDPOINT#*//}" \
    -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -o "$LOCAL_DUMP"
  
  if [[ ! -f "$LOCAL_DUMP" ]]; then
    fail "Kunne ikke hente snapshot fra S3"
  fi
  
  log "info" "Snapshot hentet: $LOCAL_DUMP"
else
  fail "S3 konfiguration mangler for rollback"
fi

# Step 3: Genopret namespace til tidligere tilstand
log "info" "Genopretter til version ${TARGET_VERSION}..."

# Opdater values-filen med target version
yq eval '.image.tag = "'"$TARGET_VERSION""'" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"
yq eval '.dolibarr.migration.enabled = false' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"

# Step 4: Redeploy med gammel version (ingen DB endnu)
log "info" "Redeployer med gammel version..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --set suspended=true \
  --wait --timeout 5m \
  --atomic

# Vent på at pods er oprettet (men suspended)
log "info" "Venter på pods..."
sleep 10

# Step 5: Restore DB fra snapshot
log "info" "Restorer DB fra snapshot..."

DB_POD="$(kubectl get pod -n "$NAMESPACE" -l app=mariadb \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$DB_POD" ]]; then
  fail "Kunne ikke finde DB-pod til restore"
fi

# Dekomprimer og indlæs dump
log "info" "Indlæser DB-dump til ${DB_POD}..."

# Kopier dump til pod og indlæs
kubectl cp "$LOCAL_DUMP" "${NAMESPACE}/${DB_POD}:/tmp/dump.sql.gz" 2>/dev/null || {
  # Fallback: pipe direkte til pod
  gunzip -c "$LOCAL_DUMP" | kubectl exec -i -n "$NAMESPACE" "$DB_POD" -- \
    mysql -u root -p"$(kubectl get secret tenant-db -n "$NAMESPACE" -o jsonpath='{.data.root_password}' | base64 -d)" 2>/dev/null || \
    fail "Kunne ikke indlæse DB-dump"
}

# Slet lokal dump
rm -f "$LOCAL_DUMP"

# Step 6: Unsuspend for at starte pods
log "info" "Unsuspend - starter pods..."
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=false \
  --wait --timeout 5m

# Step 7: Verificer health
log "info" "Verificerer tenant health..."
wait_for_healthz "$(tenant_healthz_url)"

# Step 8: Deaktiver rollback-flag
log "info" "Deaktiverer rollback-flag..."
yq eval '.rollback.enabled = false' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"
yq eval '.rollback.targetVersion = ""' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"
yq eval '.rollback.restoreFromSnapshot = ""' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"

write_status "rolled-back"
log "info" "Rollback fuldført til version ${TARGET_VERSION}"
