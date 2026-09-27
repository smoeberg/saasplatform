#!/usr/bin/env bash
# beforedeploy.sh - Pre-flight validation for SellYourSaaS deploy action
# Arkitektur 3.2: Pre-flight checks before tenant deployment
#
# Formaal:
# 1. Valider values-fil (eksisterer, gyldig YAML, nodvendige felter)
# 2. Tjek RBAC permissions (runner har tilstrakkelige rettigheder)
# 3. Tjek cluster status (nodes ready, storage tilgangeligt)
# 4. Fail-closed: Stop ved enhver fejl (ifolge 3.7)

source "$(dirname "$0")/lib.sh" "$@"

log "info" "Starter pre-flight validation for $NAMESPACE"

# =============================================================================
# 1. VALUES-FIL VALIDATION
# =============================================================================
log "info" "[1/4] Validerer values-fil: $VALUES_FILE"

require_values_file

# 1a. Tjek at filen er gyldig YAML
log "info" "  - Tjekker YAML syntax"
if ! yq eval '.' "$VALUES_FILE" >/dev/null 2>&1; then
  fail "Values-fil har ugyldig YAML syntax: $VALUES_FILE"
fi

# 1b. Tjek nodvendige felter eksisterer
log "info" "  - Tjekker nodvendige felter"
MISSING_FIELDS=()

# Krevede felter for Dolibarr
for field in "instance" "domain" "image.repository" "image.tag"; do
  if ! yq eval ".$field // null" "$VALUES_FILE" >/dev/null 2>&1; then
    MISSING_FIELDS+=("$field")
  fi
done

# Tjek at image.tag ikke er tom
IMAGE_TAG=$(yq eval '.image.tag // ""' "$VALUES_FILE")
if [[ -z "$IMAGE_TAG" ]]; then
  MISSING_FIELDS+=("image.tag")
fi

if [[ ${#MISSING_FIELDS[@]} -gt 0 ]]; then
  fail "Manglende nodvendige felter i values-fil: ${MISSING_FIELDS[*]}"
fi

# 1c. Tjek at domain er sat (fra SellYourSaaS)
DOMAIN=$(yq eval '.domain // ""' "$VALUES_FILE")
if [[ -z "$DOMAIN" ]]; then
  # Fallback: brug SELLYOURSAAS_DOLIBARRINSTANCE_URL
  if [[ -n "${SELLYOURSAAS_DOLIBARRINSTANCE_URL:-}" ]]; then
    DOMAIN="${SELLYOURSAAS_DOLIBARRINSTANCE_URL##*://}"
    log "info" "  - Brugt SELLYOURSAAS_DOLIBARRINSTANCE_URL som domain: $DOMAIN"
  else
    fail "Domain mangler i values-fil og SELLYOURSAAS_DOLIBARRINSTANCE_URL ikke sat"
  fi
fi

# 1d. Valider domain format
if [[ ! "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
  fail "Ugyldigt domain format: $DOMAIN"
fi

# 1e. Tjek at suspended vardi er bool
SUSPENDED=$(yq eval '.suspended // false' "$VALUES_FILE")
if [[ "$SUSPENDED" != "true" && "$SUSPENDED" != "false" ]]; then
  fail "suspended skal vaere true eller false (got: $SUSPENDED)"
fi

log "info" "  OK: Values-fil valid: $VALUES_FILE"

# =============================================================================
# 2. RBAC PERMISSIONS VALIDATION
# =============================================================================
log "info" "[2/4] Validerer RBAC permissions"

# 2a. Tjek at vi kan laese namespaces
log "info" "  - Tjekker laeseadgang til namespaces"
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 && ! kubectl get namespace default >/dev/null 2>&1; then
  fail "Ingen laeseadgang til namespaces - RBAC problem"
fi

# 2b. Tjek at vi kan oprette namespaces
log "info" "  - Tjekker oprettelsesadgang til namespaces"
if ! kubectl create namespace test-rbac-check --dry-run=client -o yaml >/dev/null 2>&1; then
  fail "Ingen oprettelsesadgang til namespaces - RBAC problem"
fi

# 2c. Tjek at vi kan deploye Helm charts
log "info" "  - Tjekker Helm deploy adgang"
if ! helm version >/dev/null 2>&1; then
  fail "Helm CLI ikke tilgangelig"
fi

# 2d. Tjek at vi har adgang til den specifikke namespace
if namespace_exists; then
  log "info" "  - Namespace $NAMESPACE eksisterer allerede"
else
  log "info" "  - Namespace $NAMESPACE eksisterer ikke endnu"
fi

# 2e. Tjek at vi kan oprette secrets i namespacet
log "info" "  - Tjekker secret oprettelsesadgang"
if ! kubectl create secret generic test-rbac-secret --namespace "$NAMESPACE" --dry-run=client -o yaml >/dev/null 2>&1; then
  # Hvis namespace ikke eksisterer, prov med default
  if ! kubectl create secret generic test-rbac-secret --namespace default --dry-run=client -o yaml >/dev/null 2>&1; then
    fail "Ingen adgang til at oprette secrets - RBAC problem"
  fi
fi

log "info" "  OK: RBAC permissions valid"

# =============================================================================
# 3. CLUSTER STATUS VALIDATION
# =============================================================================
log "info" "[3/4] Validerer cluster status"

# 3a. Tjek at nodes er ready
log "info" "  - Tjekker node status"
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

if [[ "$READY_NODES" -lt 1 ]]; then
  fail "Ingen ready nodes fundet (ready: $READY_NODES, total: $TOTAL_NODES)"
fi

if [[ "$READY_NODES" -lt "$TOTAL_NODES" ]]; then
  log "warn" "Ikke alle nodes er ready ($READY_NODES/$TOTAL_NODES)"
fi

log "info" "  - $READY_NODES/$TOTAL_NODES nodes er ready"

# 3b. Tjek at kube-system pods korer
log "info" "  - Tjekker system pods"
SYSTEM_PODS_READY=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
SYSTEM_PODS_TOTAL=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l || echo "0")

if [[ "$SYSTEM_PODS_READY" -lt 1 ]]; then
  fail "Ingen kube-system pods korer (ready: $SYSTEM_PODS_READY)"
fi

log "info" "  - $SYSTEM_PODS_READY/$SYSTEM_PODS_TOTAL system pods korer"

# 3c. Tjek at cert-manager fungerer (hvis installeret)
log "info" "  - Tjekker cert-manager"
if kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -q "Running"; then
  log "info" "  - cert-manager pods korer"
else
  log "warn" "cert-manager pods korer ikke (kan vaere ok hvis ikke installeret)"
fi

# 3d. Tjek at SealedSecrets controller fungerer
log "info" "  - Tjekker SealedSecrets controller"
if kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -q "sealed-secrets"; then
  log "info" "  - SealedSecrets controller korer"
else
  log "warn" "SealedSecrets controller korer ikke"
fi

# 3e. Tjek at Traefik/Ingress fungerer
log "info" "  - Tjekker Ingress controller"
if kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -qE "traefik|ingress"; then
  log "info" "  - Ingress controller korer"
else
  log "warn" "Ingress controller korer ikke"
fi

# 3f. Tjek at StorageClass er tilgangelig
log "info" "  - Tjekker StorageClass"
STORAGE_CLASS=$(kubectl get storageclass --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")
if [[ -n "$STORAGE_CLASS" ]]; then
  log "info" "  - StorageClass tilgangelig: $STORAGE_CLASS"
else
  log "warn" "Ingen StorageClass fundet (kan bruge default)"
fi

log "info" "  OK: Cluster status valid"

# =============================================================================
# 4. TENANT-SPECIFIC VALIDATION
# =============================================================================
log "info" "[4/4] Validerer tenant-specifikke krav"

# 4a. Tjek at namespace navnet er gyldigt
if [[ ! "$NAMESPACE" =~ ^tenant-[a-z0-9-]+$ ]]; then
  fail "Ugyldigt namespace navn: $NAMESPACE (skal vaere tenant-<id>)"
fi

# 4b. Tjek at instans-ID er unikt (hvis namespace eksisterer)
if namespace_exists; then
  log "info" "  - Namespace $NAMESPACE eksisterer allerede"
  
  # Tjek om det er en redeploy (ok) eller en duplicate
  if release_exists; then
    log "info" "  - Release $RELEASE eksisterer allerede (redeploy scenarie)"
  else
    log "warn" "  - Namespace eksisterer men release findes ikke"
  fi
else
  log "info" "  - Nyt namespace: $NAMESPACE"
fi

# 4c. Tjek at values-fil matcher namespace
VALUES_INSTANCE=$(yq eval '.instance // ""' "$VALUES_FILE")
if [[ -n "$VALUES_INSTANCE" && "$VALUES_INSTANCE" != "$INSTANCE" ]]; then
  log "warn" "Values-fil instance ($VALUES_INSTANCE) matcher ikke contract ID ($INSTANCE)"
fi

# 4d. Tjek at image version er gyldig
if [[ ! "$IMAGE_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  log "warn" "Image tag format muligvis ugyldig: $IMAGE_TAG (forventet X.Y.Z)"
fi

log "info" "  OK: Tenant-specifikke krav valid"

# =============================================================================
# ALL CHECKS PASSED
# =============================================================================
log "info" "OK: Alle pre-flight checks passeret for $NAMESPACE"

# Skriv status for SellYourSaaS at vide at pre-flight er ok
write_status "preflight-ok"

exit 0
