#!/usr/bin/env bash
# rollback.sh -- Gendan tenant til tidligere version efter fejlet migrering
# Arkitektur ?3.5: DB-migreringer kraever rollback-procedure
#
# Rollback-procedure (fra arkitekturdokumentet ?3.5.2):
# 1. Gendan pre-migration snapshot
# 2. Saet tidligere image-version
#
# Hvis der ikke findes et pre-migration snapshot:
# - Prov at bruge seneste natlige backup
# - Hvis ingen backup findes: fail-closed (manuel intervention nodvendig)

source "$(dirname "$0")/lib.sh" "$@"

# Parse argumenter
TARGET_VERSION=""
SNAPSHOT=""
FORCE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-version|-t)
      TARGET_VERSION="$2"
      shift 2
      ;;
    --snapshot|-s)
      SNAPSHOT="$2"
      shift 2
      ;;
    --force|-f)
      FORCE="true"
      shift
      ;;
    *)
      # Ignorer ukendte argumenter (for kompatibilitet)
      shift
      ;;
  esac
done

require_values_file

# ---- Laes rollback-indstillinger fra values ----
ROLLBACK_ENABLED=$(yq eval '.rollback.enabled // false' "$VALUES_FILE" 2>/dev/null || echo "false")

# Hvis ingen target-version er angivet, prov at laese fra values
if [[ -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION=$(yq eval '.rollback.targetVersion // ""' "$VALUES_FILE" 2>/dev/null || echo "")
fi

# Hvis ingen snapshot er angivet, prov at laese fra values
if [[ -z "$SNAPSHOT" ]]; then
  SNAPSHOT=$(yq eval '.rollback.restoreFromSnapshot // ""' "$VALUES_FILE" 2>/dev/null || echo "")
fi

# Hvis ingen snapshot, prov at finde seneste pre-migration snapshot
if [[ -z "$SNAPSHOT" ]]; then
  SNAPSHOT=$(yq eval '.dolibarr.migration.preMigrationSnapshot // ""' "$VALUES_FILE" 2>/dev/null || echo "")
fi

# ---- Valider input ----
if [[ -z "$TARGET_VERSION" ]]; then
  fail "Rollback kraever targetVersion (brug --target-version)"
fi

if [[ "$ROLLBACK_ENABLED" != "true" && "$FORCE" != "true" ]]; then
  log "info" "Rollback ikke aktiveret i values og --force ikke angivet - intet at gore"
  write_status "rollback-not-needed"
  exit 0
fi

log "info" "Starter rollback til version: ${TARGET_VERSION}"
if [[ -n "$SNAPSHOT" ]]; then
  log "info" "Restore fra snapshot: ${SNAPSHOT}"
else
  log "warn" "Ingen snapshot specificeret - vil prove at finde en"
fi

# ---- Step 1: Find snapshot ----
S3_PATH=""
LOCAL_DUMP=""

if [[ -n "$SNAPSHOT" ]]; then
  # Brug specificeret snapshot
  if [[ "$SNAPSHOT" == pre-migration-* ]]; then
    S3_PATH="${S3_PRE_MIGRATION_BUCKET:-pre-migration-backups}/${NAMESPACE}/${SNAPSHOT}.sql.gz"
  else
    S3_PATH="${S3_BUCKET}/${NAMESPACE}/${SNAPSHOT}.sql.gz"
  fi
  LOCAL_DUMP="${DUMP_DIR}/${SNAPSHOT}.sql.gz"
else
  # Prov at finde seneste pre-migration snapshot for denne tenant
  if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
    # Liste filer i S3 (simplificeret - i praksis brug S3 API)
    # For nu: prov at bruge values-filens preMigrationSnapshot
    PRE_MIGRATION_SNAPSHOT=$(yq eval '.dolibarr.migration.preMigrationSnapshot // ""' "$VALUES_FILE" 2>/dev/null || echo "")
    if [[ -n "$PRE_MIGRATION_SNAPSHOT" ]]; then
      S3_PATH="${S3_PRE_MIGRATION_BUCKET:-pre-migration-backups}/${NAMESPACE}/${PRE_MIGRATION_SNAPSHOT}.sql.gz"
      LOCAL_DUMP="${DUMP_DIR}/${PRE_MIGRATION_SNAPSHOT}.sql.gz"
      SNAPSHOT="$PRE_MIGRATION_SNAPSHOT"
    else
      fail "Ingen snapshot fundet - brug --snapshot for at specificere"
    fi
  else
    # Prov lokal dump
    PRE_MIGRATION_SNAPSHOT=$(ls -t "${DUMP_DIR}/${NAMESPACE}-pre-migration-*.sql.gz" 2>/dev/null | head -1 || echo "")
    if [[ -n "$PRE_MIGRATION_SNAPSHOT" ]]; then
      LOCAL_DUMP="$PRE_MIGRATION_SNAPSHOT"
      SNAPSHOT=$(basename "$PRE_MIGRATION_SNAPSHOT" .sql.gz)
    else
      fail "Ingen snapshot fundet - brug --snapshot for at specificere"
    fi
  fi
fi

log "info" "Brugere snapshot: ${SNAPSHOT}"

# ---- Step 2: Undeploy nuvaerende version ----
log "info" "Afinstallerer nuvaerende release..."

if release_exists; then
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 5m || {
    log "warn" "Kunne ikke afinstallere release - prover at slette manuelt"
    kubectl delete all --all -n "$NAMESPACE" --wait --timeout=5m --force --grace-period=0 || true
  }
else
  log "warn" "Release $RELEASE findes ikke - springer afinstallering over"
fi

# ---- Step 3: Hent snapshot fra S3 ----
if [[ -n "$S3_PATH" && -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  log "info" "Henter snapshot fra S3: ${S3_PATH}"
  
  curl -s -X GET "${S3_ENDPOINT}/${S3_BUCKET}/${S3_PATH}" \
    -H "Host: ${S3_BUCKET}.${S3_ENDPOINT#*//}" \
    -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -o "$LOCAL_DUMP" 2>/dev/null
  
  if [[ ! -f "$LOCAL_DUMP" || ! -s "$LOCAL_DUMP" ]]; then
    fail "Kunne ikke hente snapshot fra S3: ${S3_PATH}"
  fi
  
  log "info" "? Snapshot hentet fra S3: $LOCAL_DUMP"
else
  # Brug lokal dump
  if [[ -f "$LOCAL_DUMP" ]]; then
    log "info" "? Brugere lokal snapshot: $LOCAL_DUMP"
  else
    fail "Kunne ikke finde snapshot (S3: ${S3_PATH}, Lokal: ${LOCAL_DUMP})"
  fi
fi

# ---- Step 4: Genopret namespace til tidligere tilstand ----
log "info" "Genopretter til version ${TARGET_VERSION}..."

# Opdater values-filen med target version
log "info" "Opdaterer values-fil..."

# Gem nuvaerende version som previousTag
CURRENT_VERSION=$(yq eval '.image.tag // ""' "$VALUES_FILE" 2>/dev/null || echo "")
if [[ -n "$CURRENT_VERSION" ]]; then
  yq eval '.image.previousTag = "'"$CURRENT_VERSION""'" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
    log "warn" "Kunne ikke opdatere previousTag"
  }
fi

# Saet ny version
yq eval '.image.tag = "'"$TARGET_VERSION""'" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke saette image.tag"
}

# Deaktiver migration flag
yq eval '.dolibarr.migration.enabled = false' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke deaktivere migration flag"
}

# ---- Step 5: Redeploy med gammel version (suspended) ----
log "info" "Redeployer med gammel version (suspended)..."

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES_FILE" \
  --set suspended=true \
  --wait --timeout 5m \
  --atomic

log "info" "Namespace og resources oprettet (suspended)"

# ---- Step 6: Vent pa DB-pod ----
log "info" "Venter pa DB-pod..."

DB_POD=""
for i in $(seq 1 12); do
  DB_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=db \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$DB_POD" && "$(kubectl get pod -n "$NAMESPACE" "$DB_POD" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "$DB_POD" ]]; then
  fail "Kunne ikke finde korende DB-pod"
fi

log "info" "DB-pod fundet: ${DB_POD}"

# ---- Step 7: Restore DB fra snapshot ----
log "info" "Restorer DB fra snapshot..."

# Indlaes dump
if kubectl cp "$LOCAL_DUMP" "${NAMESPACE}/${DB_POD}:/tmp/dump.sql.gz" 2>/dev/null; then
  if kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
    sh -c 'gunzip -c /tmp/dump.sql.gz | mysql -u root -p"$(< /var/run/secrets/tenant-db/root_password)"'; then
    log "info" "? DB-dump indlaest"
  else
    # Prov med base64 password
    ROOT_PASSWORD=$(kubectl get secret tenant-db -n "$NAMESPACE" -o jsonpath='{.data.root_password}' | base64 -d 2>/dev/null || echo "")
    if [[ -n "$ROOT_PASSWORD" ]]; then
      kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
        sh -c "gunzip -c /tmp/dump.sql.gz | mysql -u root -p'${ROOT_PASSWORD}'" || {
        fail "Kunne ikke indlaese DB-dump"
      }
    else
      fail "Kunne ikke hente root_password"
    fi
  fi
else
  # Fallback: pipe direkte
  gunzip -c "$LOCAL_DUMP" | kubectl exec -i -n "$NAMESPACE" "$DB_POD" -- \
    sh -c 'mysql -u root -p"$(< /var/run/secrets/tenant-db/root_password)' || {
    fail "Kunne ikke indlaese DB-dump"
  }
fi

# Slet lokal dump
rm -f "$LOCAL_DUMP"
log "info" "Lokal dump slettet"

# ---- Step 8: Unsuspend for at starte pods ----
log "info" "Unsuspend - starter pods..."

helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=false \
  --wait --timeout 10m

log "info" "Pods startet"

# ---- Step 9: Verificer health ----
log "info" "Verificerer tenant health..."

if wait_for_healthz "$(tenant_healthz_url)"; then
  log "info" "? Healthz check bestaet"
else
  log "warn" "Healthz check fejlede"
  kubectl get pods -n "$NAMESPACE"
  kubectl logs -n "$NAMESPACE" -l app=dolibarr --tail=20 || true
  kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=db --tail=20 || true
fi

# ---- Step 10: Deaktiver rollback-flag ----
log "info" "Deaktiverer rollback-flag..."

yq eval '.rollback.enabled = false' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke deaktivere rollback flag"
}

yq eval '.rollback.targetVersion = ""' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke nulstille targetVersion"
}

yq eval '.rollback.restoreFromSnapshot = ""' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke nulstille restoreFromSnapshot"
}

# ---- Success ----
write_status "rolled-back-to-${TARGET_VERSION}"
log "info" "? Rollback fuldfort til version ${TARGET_VERSION}"
log "info" "   Snapshot: ${SNAPSHOT}"
log "info" "   Healthz: OK"
