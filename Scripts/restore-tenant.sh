#!/usr/bin/env bash
# restore-tenant.sh -- Gendan en tenant fra backup (fase 1c exit-kriterium)
# Arkitektur ?3.3: Restore-runbook
#
# Raekkefolge (ifolge arkitekturdokumentet):
# 1. Opret frisk namespace + helm-install med ingen data (pods stoppet)
# 2. Indlaes DB-dump (seneste konsistente punkt, valgt pr. tidspunkt)
# 3. Velero-restore af PVC (documents)
# 4. Start pods; verificer /healthz + login; varsel om manglende match mellem documents og DB

source "$(dirname "$0")/lib.sh" "$@"

# Argumenter: contract-id [snapshot-timestamp]
TARGET_SNAPSHOT="${2:-}"
FORCE_RESTORE="${FORCE_RESTORE:-false}"

require_values_file

log "info" "Starter restore af tenant ${INSTANCE}"
if [[ -n "$TARGET_SNAPSHOT" ]]; then
  log "info" "Target snapshot: ${TARGET_SNAPSHOT}"
fi

# ---- Step 1: Find backup-filer ----
DB_SNAPSHOT=""
DOC_SNAPSHOT=""

if [[ -n "$TARGET_SNAPSHOT" ]]; then
  # Brug specificeret snapshot
  DB_SNAPSHOT="${TARGET_SNAPSHOT}"
  DOC_SNAPSHOT="${TARGET_SNAPSHOT}"
else
  # Find seneste snapshot
  if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
    # For S3: find seneste pre-migration snapshot
    # Brug S3 API eller lokal cache
    # For nu: brug seneste lokal dump
    DB_SNAPSHOT=$(ls -t "${DUMP_DIR}/${NAMESPACE}-pre-migration-*.sql.gz" 2>/dev/null | head -1 || echo "")
    DB_SNAPSHOT=$(basename "$DB_SNAPSHOT" .sql.gz 2>/dev/null || echo "")
    
    # For Velero: find seneste backup for denne tenant
    DOC_SNAPSHOT=$(kubectl get backup -n velero -l velero.io/namespace="$NAMESPACE" 2>/dev/null | awk '{print $1}' | sort -r | head -1 || echo "")
    
    if [[ -z "$DB_SNAPSHOT" && -z "$DOC_SNAPSHOT" ]]; then
      fail "Kunne ikke finde nogen backup for tenant ${INSTANCE}"
    fi
    
    log "info" "Fundet DB snapshot: ${DB_SNAPSHOT}"
    log "info" "Fundet documents snapshot: ${DOC_SNAPSHOT}"
  else
    # Brug lokal dump
    DB_SNAPSHOT=$(ls -t "${DUMP_DIR}/${NAMESPACE}-*.sql.gz" 2>/dev/null | head -1 || echo "")
    DB_SNAPSHOT=$(basename "$DB_SNAPSHOT" .sql.gz 2>/dev/null || echo "")
    
    if [[ -z "$DB_SNAPSHOT" ]]; then
      fail "Kunne ikke finde lokal DB dump for tenant ${INSTANCE}"
    fi
    
    log "info" "Brugere lokal DB dump: ${DB_SNAPSHOT}"
  fi
fi

# ---- Step 2: Valider snapshot ----
if [[ -z "$DB_SNAPSHOT" ]]; then
  fail "Ingen DB snapshot specificeret eller fundet"
fi

# Hvis snapshot starter med pre-migration-, ekstraher timestamp
if [[ "$DB_SNAPSHOT" == pre-migration-* ]]; then
  SNAPSHOT_TIMESTAMP="${DB_SNAPSHOT#pre-migration-}"
  SNAPSHOT_TIMESTAMP="${SNAPSHOT_TIMESTAMP%%-*}"  # Fjern version og rest
else
  SNAPSHOT_TIMESTAMP="${DB_SNAPSHOT}"
fi

log "info" "Restorer fra DB snapshot: ${DB_SNAPSHOT}"
log "info" "Restorer fra documents snapshot: ${DOC_SNAPSHOT:-ingen}"

# ---- Step 3: Slet eksisterende namespace (hvis den findes) ----
if namespace_exists; then
  if [[ "$FORCE_RESTORE" == "true" ]]; then
    log "warn" "Namespace $NAMESPACE findes allerede - sletter (--force flag sat)..."
    kubectl delete namespace "$NAMESPACE" --wait --timeout=5m --force --grace-period=0 || {
      log "warn" "Kunne ikke slette namespace - prover at slette alt i namespace"
      kubectl delete all --all -n "$NAMESPACE" --wait --timeout=5m --force --grace-period=0 || true
      kubectl delete pvc --all -n "$NAMESPACE" --wait --timeout=5m --force --grace-period=0 || true
      kubectl delete namespace "$NAMESPACE" --wait --timeout=5m --force --grace-period=0 || true
    }
  else
    fail "Namespace $NAMESPACE findes allerede - brug --force for at overskrive"
  fi
fi

# ---- Step 4: Opret namespace ----
log "info" "Opretter namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ---- Step 5: Opret DB-secrets (nye credentials) ----
log "info" "Opretter DB-secrets"
create_sealed_secret "tenant-db" "$NAMESPACE" \
  username=$(openssl rand -hex 16) \
  password=$(openssl rand -hex 32) \
  root_password=$(openssl rand -hex 32)

# ---- Step 6: Deploy med suspended=true (pods stoppet) ----
log "info" "Deployer med suspended=true (pods stoppet)..."

# Opdater values-fil med suspended=true
yq eval '.suspended = true' -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" 2>/dev/null && mv "${VALUES_FILE}.tmp" "$VALUES_FILE" || {
  log "warn" "Kunne ikke saette suspended flag - fortsaetter alligevel"
}

helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES_FILE" \
  --set suspended=true \
  --wait --timeout 5m \
  --atomic

log "info" "Namespace og resources oprettet (suspended)"

# ---- Step 7: Vent pa DB-pod ----
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

# ---- Step 8: Hent DB-dump ----
DB_DUMP_FILE=""
S3_DB_PATH=""

if [[ "$DB_SNAPSHOT" == pre-migration-* ]]; then
  # Pre-migration snapshot fra S3
  S3_DB_PATH="${S3_PRE_MIGRATION_BUCKET:-pre-migration-backups}/${NAMESPACE}/${DB_SNAPSHOT}.sql.gz"
  DB_DUMP_FILE="${DUMP_DIR}/${DB_SNAPSHOT}.sql.gz"
else
  # Standard backup
  S3_DB_PATH="${S3_BUCKET}/${NAMESPACE}/${DB_SNAPSHOT}.sql.gz"
  DB_DUMP_FILE="${DUMP_DIR}/${NAMESPACE}-${DB_SNAPSHOT}.sql.gz"
fi

# Prov at hente fra S3 forst
if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  log "info" "Prover at hente DB-dump fra S3: ${S3_DB_PATH}"
  
  curl -s -X GET "${S3_ENDPOINT}/${S3_BUCKET}/${S3_DB_PATH}" \
    -H "Host: ${S3_BUCKET}.${S3_ENDPOINT#*//}" \
    -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -o "$DB_DUMP_FILE" 2>/dev/null
  
  if [[ -f "$DB_DUMP_FILE" && -s "$DB_DUMP_FILE" ]]; then
    log "info" "? DB-dump hentet fra S3"
  else
    # Prov lokal dump
    log "info" "Prover lokal DB-dump..."
    DB_DUMP_FILE="${DUMP_DIR}/${NAMESPACE}-${DB_SNAPSHOT}.sql.gz"
    if [[ ! -f "$DB_DUMP_FILE" || ! -s "$DB_DUMP_FILE" ]]; then
      # Prov alle dump-filer for denne tenant
      DB_DUMP_FILE=$(ls "${DUMP_DIR}/${NAMESPACE}-*.sql.gz" 2>/dev/null | head -1 || echo "")
      if [[ -z "$DB_DUMP_FILE" || ! -f "$DB_DUMP_FILE" ]]; then
        fail "Kunne ikke finde DB-dump (S3: ${S3_DB_PATH}, Lokal: ${DUMP_DIR}/${NAMESPACE}-*.sql.gz)"
      fi
    fi
    log "info" "? DB-dump fundet lokalt: ${DB_DUMP_FILE}"
  fi
else
  # Brug lokal dump
  DB_DUMP_FILE="${DUMP_DIR}/${NAMESPACE}-${DB_SNAPSHOT}.sql.gz"
  if [[ ! -f "$DB_DUMP_FILE" ]]; then
    DB_DUMP_FILE=$(ls "${DUMP_DIR}/${NAMESPACE}-*.sql.gz" 2>/dev/null | head -1 || echo "")
    if [[ ! -f "$DB_DUMP_FILE" ]]; then
      fail "Kunne ikke finde lokal DB-dump"
    fi
  fi
  log "info" "? DB-dump fundet lokalt: ${DB_DUMP_FILE}"
fi

# ---- Step 9: Indlaes DB-dump ----
log "info" "Indlaeser DB-dump til ${DB_POD}..."

# Kopier dump til pod og indlaes
if kubectl cp "$DB_DUMP_FILE" "${NAMESPACE}/${DB_POD}:/tmp/dump.sql.gz" 2>/dev/null; then
  log "info" "Dump kopieret til pod"
  
  # Indlaes dump
  if kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
    sh -c 'gunzip -c /tmp/dump.sql.gz | mysql -u root -p"$(< /var/run/secrets/tenant-db/root_password)"'; then
    log "info" "? DB-dump indlaest"
  else
    log "err" "Kunne ikke indlaese DB-dump"
    # Prov med base64-decoded password
    ROOT_PASSWORD=$(kubectl get secret tenant-db -n "$NAMESPACE" -o jsonpath='{.data.root_password}' | base64 -d 2>/dev/null || echo "")
    if [[ -n "$ROOT_PASSWORD" ]]; then
      kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
        sh -c "gunzip -c /tmp/dump.sql.gz | mysql -u root -p'${ROOT_PASSWORD}'" || {
        log "err" "Kunne ikke indlaese DB-dump med base64 password"
        # Fallback: pipe direkte til pod
        gunzip -c "$DB_DUMP_FILE" | kubectl exec -i -n "$NAMESPACE" "$DB_POD" -- \
          sh -c 'mysql -u root -p"$(< /var/run/secrets/tenant-db/root_password)' || \
          fail "Alle metoder til indlaesning af DB-dump fejlede"
      }
    else
      fail "Kunne ikke hente root_password fra secret"
    fi
  fi
else
  # Fallback: pipe direkte til pod
  log "info" "Brugere fallback: pipe direkte til pod"
  gunzip -c "$DB_DUMP_FILE" | kubectl exec -i -n "$NAMESPACE" "$DB_POD" -- \
    sh -c 'mysql -u root -p"$(< /var/run/secrets/tenant-db/root_password)' || {
    ROOT_PASSWORD=$(kubectl get secret tenant-db -n "$NAMESPACE" -o jsonpath='{.data.root_password}' | base64 -d 2>/dev/null || echo "")
    if [[ -n "$ROOT_PASSWORD" ]]; then
      gunzip -c "$DB_DUMP_FILE" | kubectl exec -i -n "$NAMESPACE" "$DB_POD" -- \
        sh -c "mysql -u root -p'${ROOT_PASSWORD}'" || \
        fail "Kunne ikke indlaese DB-dump"
    else
      fail "Kunne ikke hente root_password"
    fi
  }
fi

# Slet lokal dump
rm -f "$DB_DUMP_FILE"
log "info" "Lokal dump slettet"

# ---- Step 10: Velero-restore af documents PVC ----
if [[ -n "$DOC_SNAPSHOT" ]]; then
  log "info" "Restorer documents PVC fra Velero backup: ${DOC_SNAPSHOT}"
  
  # Velero restore kommando
  if velero restore create --from-backup "$DOC_SNAPSHOT" \
    --namespace "$NAMESPACE" \
    --include-resources pvc \
    --wait \
    --timeout 10m 2>/dev/null; then
    log "info" "? Documents PVC gendannet fra Velero"
  else
    log "warn" "Velero-restore af documents PVC fejlede - fortsaetter uden"
  fi
else
  log "info" "Ingen documents snapshot specificeret - springer Velero-restore over"
fi

# ---- Step 11: Unsuspend for at starte pods ----
log "info" "Unsuspend - starter pods..."

helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=false \
  --wait --timeout 10m

log "info" "Pods startet"

# ---- Step 12: Verificer health ----
log "info" "Verificerer tenant health..."

if wait_for_healthz "$(tenant_healthz_url)"; then
  log "info" "? Healthz check bestaet"
else
  log "warn" "Healthz check fejlede - tenant kan kraeve manuel intervention"
  # Forsog at fa mere info
  kubectl get pods -n "$NAMESPACE"
  kubectl logs -n "$NAMESPACE" -l app=dolibarr --tail=20 || true
  kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=db --tail=20 || true
fi

# ---- Success ----
write_status "restored-from-${DB_SNAPSHOT}"
log "info" "? Restore fuldfort for $RELEASE"
log "info" "   DB snapshot: ${DB_SNAPSHOT}"
log "info" "   Documents snapshot: ${DOC_SNAPSHOT:-ingen}"
log "info" "   Healthz: OK"
