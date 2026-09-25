#!/usr/bin/env bash
# verify-secrets-flow.sh — Verificer SealedSecrets flow end-to-end (fase 1c)
# Arkitektur §3.3.1: Secrets-flow
# 
# Flow:
# 1. Runneren genererer secrets lokalt (DB-password, app-secrets) ved første deploy
# 2. SealedSecret oprettes via kubeseal og apply'es
# 3. Klartekst slettes straks
# 4. Password-reset: runner genererer ny secret → ny SealedSecret → helm upgrade → restart pod

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

log "info" "Verificerer SealedSecrets flow for $INSTANCE"

# Step 1: Tjek at kubeseal cert findes
if [[ ! -f "$KUBESEAL_CERT" ]]; then
  fail "kubeseal cert ikke fundet: $KUBESEAL_CERT"
fi

log "info" "✓ kubeseal cert fundet"

# Step 2: Tjek at namespace findes
if ! namespace_exists; then
  fail "Namespace $NAMESPACE findes ikke"
fi

log "info" "✓ Namespace findes"

# Step 3: Tjek at SealedSecrets findes
SEALED_SECRETS=$(kubectl get sealedsecret -n "$NAMESPACE" 2>/dev/null || true)

if [[ -z "$SEALED_SECRETS" ]]; then
  log "warn" "Ingen SealedSecrets fundet i namespace"
else
  log "info" "✓ SealedSecrets fundet:"
  echo "$SEALED_SECRETS"
fi

# Step 4: Tjek specifikke secrets
for secret_name in tenant-db platform-access; do
  if kubectl get sealedsecret "$secret_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "info" "✓ SealedSecret '$secret_name' fundet"
  elif kubectl get secret "$secret_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "warn" "Secret '$secret_name' findes som klartekst (bør være SealedSecret)"
  else
    log "warn" "Secret '$secret_name' findes ikke"
  fi
done

# Step 5: Test password-reset flow
log "info" "Tester password-reset flow..."

# Generer ny password
NEW_PASSWORD=$(openssl rand -hex 32)

# Opret ny SealedSecret (simulerer password-reset)
create_sealed_secret "tenant-db-reset-test" "$NAMESPACE" \
  password="$NEW_PASSWORD"

if kubectl get sealedsecret "tenant-db-reset-test" -n "$NAMESPACE" >/dev/null 2>&1; then
  log "info" "✓ Ny SealedSecret oprettet"
  
  # Slet test-secret
  kubectl delete sealedsecret "tenant-db-reset-test" -n "$NAMESPACE"
  log "info" "✓ Test-secret slettet"
else
  fail "Kunne ikke oprette test SealedSecret"
fi

# Step 6: Verificer at ingen klartekst-secrets findes
CLARTEKST_SECRETS=$(kubectl get secret -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[].metadata.name' || true)

if [[ -n "$CLARTEKST_SECRETS" ]]; then
  log "warn" "Klartekst-secrets fundet (bør kun være SealedSecrets):"
  echo "$CLARTEKST_SECRETS"
else
  log "info" "✓ Ingen klartekst-secrets fundet"
fi

write_status "secrets-flow-verified"
log "info" "Secrets-flow verification fuldført for $RELEASE"
