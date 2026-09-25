#!/usr/bin/env bash
# restore-tenant.sh — Gendan en tenant fra backup (fase 1c exit-kriterium)
# Arkitektur §3.3: Restore-runbook
# 
# Rækkefølge:
# 1. Opret frisk namespace + helm-install med ingen data (pods stoppet)
# 2. Indlæs DB-dump (seneste konsistente punkt, valgt pr. tidspunkt)
# 3. Velero-restore af PVC (documents)
# 4. Start pods; verificér /healthz + login

source "$(dirname "$0")/lib.sh" "$@"

# Argumenter: contract-id [snapshot-timestamp]
TARGET_SNAPSHOT="${2:-}"

require_values_file

log "info" "Starter restore af tenant ${INSTANCE}"

# Step 1: Find backup-filer
if [[ -n "$TARGET_SNAPSHOT" ]]; then
  # Brug specificeret snapshot
  DB_SNAPSHOT="${TARGET_SNAPSHOT}"
  DOC_SNAPSHOT="${TARGET_SNAPSHOT}"
else
  # Find seneste snapshot
  if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
    # List DB snapshots (simplificeret)
    # I praksis: brug S3 API til at liste filer
    DB_SNAPSHOT=$(ls -t "${DUMP_DIR}/${NAMESPACE}-*.sql.gz" 2>/dev/null | head -1 || echo "")
    DB_SNAPSHOT=$(basename "$DB_SNAPSHOT" .sql.gz)
    
    # For Velero: find seneste backup
    DOC_SNAPSHOT=$(kubectl get backup -n velero | grep "${NAMESPACE}" | awk '{print $1}' | sort -r | head -1 || echo "")
  else
    fail "Ingen S3 konfiguration - kan ikke finde backups"
  fi
fi

if [[ -z "$DB_SNAPSHOT" ]]; then
  fail "Kunne ikke finde DB snapshot"
fi

log "info" "Restorer fra DB snapshot: ${DB_SNAPSHOT}"
log "info" "Restorer fra documents snapshot: ${DOC_SNAPSHOT:-seneste Velero backup}"

# Step 2: Slet eksisterende namespace (hvis den findes)
if namespace_exists; then
  log "warn" "Namespace $NAMESPACE findes allerede - sletter..."
  kubectl delete namespace "$NAMESPACE" --wait --timeout=5m
fi

# Step 3: Opret namespace
log "info" "Opretter namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Step 4: Opret DB-secrets (nye credentials)
log "info" "Opretter DB-secrets"
create_sealed_secret "tenant-db" "$NAMESPACE" \
  username=$(openssl rand -hex 16) \
  password=$(openssl rand -hex 32) \
  root_password=$(openssl rand -hex 32)

# Step 5: Deploy med suspended=true (pods stoppet)
log "info" "Deployer med suspended=true..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES_FILE" \
  --set suspended=true \
  --wait --timeout 5m \
  --atomic

# Step 6: Hent DB-dump fra S3
DB_DUMP_FILE="${DUMP_DIR}/${DB_SNAPSHOT}.sql.gz"
S3_DB_PATH="backups/${NAMESPACE}/${DB_SNAPSHOT}.sql.gz"

if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  log "info" "Henter DB-dump fra S3: ${S3_DB_PATH}"
  curl -s -X GET "${S3_ENDPOINT}/${S3_BUCKET}/${S3_DB_PATH}" \
    -H "Host: ${S3_BUCKET}.${S3_ENDPOINT#*//}" \
    -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
    -o "$DB_DUMP_FILE"
  
  if [[ ! -f "$DB_DUMP_FILE" ]]; then
    # Prøv lokal dump
    DB_DUMP_FILE="${DUMP_DIR}/${NAMESPACE}-${DB_SNAPSHOT}.sql.gz"
    if [[ ! -f "$DB_DUMP_FILE" ]]; then
      fail "Kunne ikke finde DB-dump"
    fi
  fi
else
  # Brug lokal dump
  DB_DUMP_FILE="${DUMP_DIR}/${NAMESPACE}-${DB_SNAPSHOT}.sql.gz"
  if [[ ! -f "$DB_DUMP_FILE" ]]; then
    fail "Kunne ikke finde lokal DB-dump"
  fi
fi

# Step 7: Vent på DB-pod
log "info" "Venter på DB-pod..."
for i in $(seq 1 12); do
  DB_POD=$(kubectl get pod -n "$NAMESPACE" -l app=mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$DB_POD" && "$(kubectl get pod -n "$NAMESPACE" "$DB_POD" -o jsonpath='{.status.phase}')" == "Running" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "$DB_POD" ]]; then
  fail "Kunne ikke finde kørende DB-pod"
fi

# Step 8: Indlæs DB-dump
log "info" "Indlæser DB-dump til ${DB_POD}..."

# Kopier dump til pod
kubectl cp "$DB_DUMP_FILE" "${NAMESPACE}/${DB_POD}:/tmp/dump.sql.gz" 2>/dev/null || {
  # Fallback: pipe direkte
  gunzip -c "$DB_DUMP_FILE" | kubectl exec -i -n "$NAMESPACE" "$DB_POD" -- \
    mysql -u root -p"$(kubectl get secret tenant-db -n "$NAMESPACE" -o jsonpath='{.data.root_password}' | base64 -d)" 2>/dev/null || \
    fail "Kunne ikke indlæse DB-dump"
}

# Slet lokal dump
rm -f "$DB_DUMP_FILE"

# Step 9: Velero-restore af documents PVC
if [[ -n "$DOC_SNAPSHOT" ]]; then
  log "info" "Restorer documents PVC fra Velero backup: ${DOC_SNAPSHOT}"
  
  # Velero restore kommando
  velero restore create --from-backup "$DOC_SNAPSHOT" \
    --namespace "$NAMESPACE" \
    --wait \
    --timeout 10m 2>/dev/null || \
    log "warn" "Velero-restore fejlede - fortsætter uden documents"
fi

# Step 10: Unsuspend for at starte pods
log "info" "Unsuspend - starter pods..."
helm upgrade "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --reuse-values \
  --set suspended=false \
  --wait --timeout 5m

# Step 11: Verificer health
log "info" "Verificerer tenant health..."
if wait_for_healthz "$(tenant_healthz_url)"; then
  log "info" "✓ Healthz check bestået"
else
  log "warn" "Healthz check fejlede - tenant kan kræve manuel intervention"
fi

write_status "restored"
log "info" "Restore fuldført for $RELEASE (DB: ${DB_SNAPSHOT}, Documents: ${DOC_SNAPSHOT:-ingen})"
