#!/usr/bin/env bash
# migrate.sh — Håndterer Dolibarr DB-migrering med pre-migration snapshot
# Arkitektur §3.5: DB-migreringer er risikable, kræver snapshot + rollback-plan
#
# Migreringsprocedure:
# 1. Tag pre-migration snapshot (mysqldump --single-transaction)
# 2. Upload til S3 (fail-closed hvis upload fejler)
# 3. Opdater Helm-values med snapshot info
# 4. Opdater image til ny version
# 5. Vent på pods og healthz

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

# ---- Versionscheck ----
NEW_VERSION="${SELLYOURSAAS_VERSION:-}"
CURRENT_VERSION=$(helm get values "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.image.tag // ""' || echo "")

# Hvis ingen versionsændring, intet at gøre
if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
  log "info" "Ingen versionsændring ($CURRENT_VERSION) - ingen migrering nødvendig"
  write_status "migration-not-needed"
  exit 0
fi

# Hvis ingen versioner, kan vi ikke bestemme migrering
if [[ -z "$NEW_VERSION" || -z "$CURRENT_VERSION" ]]; then
  log "warn" "Kunne ikke bestemme versionsændring (current=$CURRENT_VERSION, new=$NEW_VERSION) - antager ingen migrering"
  write_status "migration-skipped"
  exit 0
fi

# ---- Pre-migration snapshot ----
# Generer snapshot-tag: pre-migration-{version}-{timestamp}
SNAPSHOT_TAG="pre-migration-${NEW_VERSION}-$(date +%Y%m%d%H%M%S)"
SNAPSHOT_FILE="${DUMP_DIR}/${NAMESPACE}-${SNAPSHOT_TAG}.sql.gz"
S3_PATH="${S3_PRE_MIGRATION_BUCKET:-pre-migration-backups}/${NAMESPACE}/${SNAPSHOT_TAG}.sql.gz"

log "info" "Starter DB-migrering: ${CURRENT_VERSION} → ${NEW_VERSION}"
log "info" "Snapshot-tag: ${SNAPSHOT_TAG}"

# Step 1: Find DB-pod (bruger det nye label fra erp-tenant chartet)
DB_POD="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=db \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$DB_POD" ]]; then
  # Fallback: prøv det gamle label
  DB_POD="$(kubectl get pod -n "$NAMESPACE" -l app=mariadb \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$DB_POD" ]]; then
    fail "Kunne ikke finde DB-pod for snapshot (prøvede app.kubernetes.io/component=db og app=mariadb)"
  fi
  log "warn" "Brugte fallback label (app=mariadb) for DB-pod"
fi

log "info" "Tager pre-migration DB-snapshot fra pod: ${DB_POD}"

# Step 2: Tag dump med mysqldump --single-transaction (InnoDB-konsistenspunkt)
if ! kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  sh -c 'mysqldump --single-transaction --quick --skip-add-drop-table --routines --triggers --events --all-databases' | gzip > "$SNAPSHOT_FILE"; then
  fail "Kunne ikke tage DB-snapshot fra ${DB_POD}"
fi

# Verificer dump-fil
if [[ ! -s "$SNAPSHOT_FILE" ]]; then
  rm -f "$SNAPSHOT_FILE"
  fail "Snapshot-fil er tom"
fi

log "info" "Snapshot gemt lokalt: $SNAPSHOT_FILE ($(stat -c%s "$SNAPSHOT_FILE" | numfmt --to=iec) bytes)"

# ---- Upload til S3 (kritisk afhængighed - fail-closed) ----
S3_UPLOAD_ENABLED="${S3_UPLOAD_ENABLED:-true}"

if [[ "$S3_UPLOAD_ENABLED" == "true" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  log "info" "Uploader snapshot til S3..."
  
  # Upload via s3_upload funktion
  if ! s3_upload "$SNAPSHOT_FILE" "$S3_PATH"; then
    # Fail-closed: slet lokal snapshot, afbryd migrering
    rm -f "$SNAPSHOT_FILE"
    fail "S3-upload fejlede - migrering afbrudt (fail-closed, §3.5.5)"
  fi
  
  # Verificer upload med HEAD request
  HTTP_CODE=$(curl -s -I "${S3_ENDPOINT}/${S3_BUCKET}/${S3_PATH}" \
    -H "Host: ${S3_BUCKET}.${S3_ENDPOINT#*//}" \
    -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -w "%{http_code}" 2>/dev/null || echo "000")
  
  if [[ "$HTTP_CODE" != "200" ]]; then
    rm -f "$SNAPSHOT_FILE"
    fail "S3-verifikation fejlede (HTTP ${HTTP_CODE}) - migrering afbrudt"
  fi
  
  log "info" "✅ Snapshot uploadet og verificeret: S3://${S3_BUCKET}/${S3_PATH}"
  
  # Slet lokal snapshot for at spare plads
  rm -f "$SNAPSHOT_FILE"
  log "info" "Lokal snapshot slettet"
else
  if [[ "$S3_UPLOAD_ENABLED" == "true" ]]; then
    log "warn" "S3 ikke konfigureret - snapshot forbliver lokalt (ikke fail-closed i dev)"
  else
    log "info" "S3 upload deaktiveret - snapshot forbliver lokalt"
  fi
fi

# ---- Opdater Helm-values med pre-migration info ----
log "info" "Opdaterer values med pre-migration snapshot..."

# Tilføj pre-migration snapshot til values-filen
if ! yq eval '.dolibarr.migration.preMigrationSnapshot = "'"$SNAPSHOT_TAG""'" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null; then
  log "warn" "Kunne ikke opdatere preMigrationSnapshot med yq - prøver manuel metode"
  # Manuel fallback
  echo "dolibarr:" >> "${VALUES_FILE}.tmp"
  echo "  migration:" >> "${VALUES_FILE}.tmp"
  echo "    preMigrationSnapshot: \"$SNAPSHOT_TAG\"" >> "${VALUES_FILE}.tmp"
  cat "$VALUES_FILE" | grep -v "preMigrationSnapshot" >> "${VALUES_FILE}.tmp" 2>/dev/null || true
  mv "${VALUES_FILE}.tmp" "$VALUES_FILE"
else
  mv "${VALUES_FILE}.tmp" "$VALUES_FILE"
fi

# Gem tidligere image-tag for rollback
yq eval '.image.previousTag = "'"$CURRENT_VERSION""'" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke opdatere previousTag"
}

# Marker migrering som aktiv
yq eval '.dolibarr.migration.enabled = true' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke aktivere migration flag"
}

# ---- Step 3: Opdater image til ny version ----
log "info" "Opdaterer image til ny version: ${NEW_VERSION}"

# Opdater Helm release med ny version
if ! helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --set image.tag="$NEW_VERSION" \
  --wait --timeout 15m \
  --atomic; then
  
  # Hvis migrering fejler: rul tilbage
  log "err" "Migrering til ${NEW_VERSION} fejlede - prøver rollback..."
  
  # Forsøg rollback
  ./Scripts/rollback.sh "$INSTANCE" --target-version "$CURRENT_VERSION" --snapshot "$SNAPSHOT_TAG" --force || {
    fail "Migrering fejlede og rollback fejlede - manuel intervention nødvendig"
  }
  
  # Gen-start migrering (for at undgå at blive i en dårlig tilstand)
  fail "Migrering fejlede - rollback udført til ${CURRENT_VERSION}"
fi

# ---- Step 4: Vent på pods og healthz ----
log "info" "Venter på pods og healthz..."

# Vent på at alle pods er ready
if ! kubectl wait --for=condition=ready pod -n "$NAMESPACE" --all --timeout=10m; then
  log "warn" "Pods er ikke alle ready inden for timeout"
  # Tjek specifikke pods
  DOLIBARR_READY=$(kubectl get pod -n "$NAMESPACE" -l app=dolibarr -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  MARIADB_READY=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=db -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  
  if [[ "$DOLIBARR_READY" != "True" || "$MARIADB_READY" != "True" ]]; then
    fail "Kritiske pods er ikke ready efter migrering"
  fi
fi

# Vent på healthz
if ! wait_for_healthz "$(tenant_healthz_url)"; then
  log "warn" "Healthz check fejlede - kan skyldes migreringsproblemer"
  # Prøv at logge DB fejl
  kubectl logs -n "$NAMESPACE" -l app=mariadb --tail=50 || true
  kubectl logs -n "$NAMESPACE" -l app=dolibarr --tail=50 || true
  fail "Healthz check fejlede efter migrering"
fi

# ---- Success ----
write_status "migrated-to-${NEW_VERSION}"
log "info" "✅ Migrering fuldført: ${CURRENT_VERSION} → ${NEW_VERSION}"
log "info" "Pre-migration snapshot: ${SNAPSHOT_TAG}"
log "info" "Healthz: OK"
