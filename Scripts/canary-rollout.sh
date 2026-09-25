#!/usr/bin/env bash
# canary-rollout.sh - Canary-rollout rutine for Dolibarr-opdateringer
# Arkitektur §3.5: Canary-algoritme for opdateringer
#
# Algoritme:
# 1. Tenants grupperes pr. strata (plan × deployment-server)
# 2. Inden for hvert stratum: tenants sorteres pr. kontrakt-id
# 3. Rotationsindeks gemmes i Dolibarr (extrafield)
# 4. Næste canary = indeks mod N, derefter indeks+1 osv.
# 5. Med 10 tenants og 5-10% canary: 1 tenant pr. gang
# 6. Rotationen sikrer at alle gennemgår canary over tid

set -euo pipefail

# Konfiguration
NEW_VERSION="${SELLYOURSAAS_VERSION:-}"
CANARY_PERCENTAGE="${CANARY_PERCENTAGE:-5}"  # 5-10%
STRATA="${STRATA:-standard}"  # plan type
DEPLOYMENT_SERVER="${DEPLOYMENT_SERVER:-k8s-prod}"

# Hent liste af tenants fra SellYourSaaS
# For nu: simuler med kubectl
TENANT_NAMESPACES=$(kubectl get namespace -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-' | sort)

if [[ -z "$TENANT_NAMESPACES" ]]; then
  echo "FATAL: Ingen tenants fundet"
  exit 1
fi

# Filter efter strata (plan type)
# I praksis: hent fra SellYourSaaS API
FILTERED_TENANTS=()
for ns in $TENANT_NAMESPACES; do
  # Ekstraher contract-id fra namespace
  CONTRACT_ID="${ns#tenant-}"
  
  # Tjek om tenant hører til dette strata
  # For nu: antag alle hører til standard
  FILTERED_TENANTS+=("$ns")
done

TOTAL_TENANTS=${#FILTERED_TENANTS[@]}

if [[ $TOTAL_TENANTS -eq 0 ]]; then
  echo "INFO: Ingen tenants i strata $STRATA"
  exit 0
fi

echo "Canary-rollout: $TOTAL_TENANTS tenants i strata $STRATA"
echo "Canary percentage: ${CANARY_PERCENTAGE}%"

# Beregn canary count
CANARY_COUNT=$(( TOTAL_TENANTS * CANARY_PERCENTAGE / 100 ))
if [[ $CANARY_COUNT -eq 0 ]]; then
  CANARY_COUNT=1
fi

echo "Canary count: $CANARY_COUNT tenant(s)"

# Hent rotationsindeks fra Dolibarr (extrafield)
# For nu: brug en lokal fil som simulation
INDEX_FILE="/var/lib/saasplatform/canary-index-${STRATA}-${DEPLOYMENT_SERVER}.txt"

if [[ -f "$INDEX_FILE" ]]; then
  CURRENT_INDEX=$(cat "$INDEX_FILE")
else
  CURRENT_INDEX=0
fi

echo "Nuværende rotationsindeks: $CURRENT_INDEX"

# Beregn hvilke tenants der skal opdateres
CANARY_TENANTS=()
for i in $(seq 0 $((TOTAL_TENANTS-1))); do
  # Check if this tenant should be in the canary group
  # Using rotation: (current_index + i) mod total = position in rotation
  POSITION=$(( (CURRENT_INDEX + i) % TOTAL_TENANTS ))
  
  if [[ $POSITION -lt $CANARY_COUNT ]]; then
    CANARY_TENANTS+=("${FILTERED_TENANTS[$i]}")
    echo "  Canary: ${FILTERED_TENANTS[$i]} (position $POSITION)"
  fi
done

if [[ ${#CANARY_TENANTS[@]} -eq 0 ]]; then
  echo "FATAL: Ingen canary tenants valgt"
  exit 1
fi

echo ""
echo "Canary tenants til opdatering:"
for ns in "${CANARY_TENANTS[@]}"; do
  echo "  - $ns"
done

# Opdater canary tenants
FAILED=0
SUCCESS=0

for ns in "${CANARY_TENANTS[@]}"; do
  CONTRACT_ID="${ns#tenant-}"
  
  echo ""
  echo "Opdaterer canary tenant: $ns (contract: $CONTRACT_ID)"
  
  # Tjek om dette er en migrerende version
  CURRENT_VERSION=$(helm get values "tenant" -n "$ns" -o json 2>/dev/null | jq -r '.image.tag // ""' || echo "")
  
  if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
    echo "  Ingen versionsændring for $ns"
    continue
  fi
  
  # Tag pre-migration snapshot for DB-migrerende versioner
  if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
    echo "  Tager pre-migration snapshot..."
    if ! SELLYOURSAAS_INSTANCE_NAME="$CONTRACT_ID" SELLYOURSAAS_VERSION="$NEW_VERSION" bash "$(dirname "$0")/migrate.sh" "$CONTRACT_ID"; then
      echo "  ✗ Pre-migration snapshot fejlede for $ns"
      FAILED=$((FAILED+1))
      continue
    fi
  fi
  
  # Opdater tenant
  VALUES_FILE="/etc/saasplatform/values/${ns}.yaml"
  
  # Opdater version i values-fil
  if [[ -f "$VALUES_FILE" ]]; then
    yq eval ".image.tag = \"$NEW_VERSION\"" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"
  fi
  
  # Kør refresh (helm upgrade)
  if SELLYOURSAAS_INSTANCE_NAME="$CONTRACT_ID" SELLYOURSAAS_VERSION="$NEW_VERSION" bash "$(dirname "$0")/refresh.sh" "$CONTRACT_ID"; then
    echo "  ✓ Canary tenant $ns opdateret til version $NEW_VERSION"
    SUCCESS=$((SUCCESS+1))
  else
    echo "  ✗ Canary tenant $ns fejlede"
    FAILED=$((FAILED+1))
    
    # Forsøg rollback
    echo "  Forsøger rollback..."
    if SELLYOURSAAS_INSTANCE_NAME="$CONTRACT_ID" bash "$(dirname "$0")/rollback.sh" "$CONTRACT_ID"; then
      echo "  ✓ Rollback lykkedes for $ns"
    else
      echo "  ✗ Rollback fejlede for $ns - manuel intervention nødvendig"
    fi
  fi
done

echo ""
echo "Canary-rollout resultat: $SUCCESS success, $FAILED failed"

# Opdater rotationsindeks
NEW_INDEX=$(( (CURRENT_INDEX + CANARY_COUNT) % TOTAL_TENANTS ))
echo "Nyt rotationsindeks: $NEW_INDEX"
echo "$NEW_INDEX" > "$INDEX_FILE"

# Hvis alle canary tenants lykkedes, fortsæt med fuld rollout
if [[ $FAILED -eq 0 ]]; then
  echo ""
  echo "Alle canary tenants opdateret - fortsætter med fuld rollout"
  
  # Vent på canary-vindue (se §3.5)
  # Vindue = maks. (observed migrationsvarighed × 3, 30 min.)
  CANARY_WINDOW=$(( 30 * 60 ))  # 30 minutter default
  
  echo "Venter på canary-vindue: ${CANARY_WINDOW}s"
  sleep $CANARY_WINDOW
  
  # Verificer alle canary tenants er sunde
  ALL_HEALTHY=true
  for ns in "${CANARY_TENANTS[@]}"; do
    CONTRACT_ID="${ns#tenant-}"
    HEALTHZ_URL="https://${CONTRACT_ID}.${TENANT_DOMAIN:-tenants.example.com}/healthz"
    
    if ! curl -fsS -o /dev/null -m 5 "$HEALTHZ_URL"; then
      echo "  ✗ Canary tenant $ns er ikke sund"
      ALL_HEALTHY=false
      break
    fi
  done
  
  if [[ "$ALL_HEALTHY" == "true" ]]; then
    echo ""
    echo "Alle canary tenants er sunde - starter fuld rollout"
    
    # Opdater alle remaining tenants
    REMAINING_TENANTS=()
    for ns in "${FILTERED_TENANTS[@]}"; do
      if [[ ! " ${CANARY_TENANTS[@]} " =~ " ${ns} " ]]; then
        REMAINING_TENANTS+=("$ns")
      fi
    done
    
    for ns in "${REMAINING_TENANTS[@]}"; do
      CONTRACT_ID="${ns#tenant-}"
      echo "Opdaterer tenant: $ns"
      
      # Opdater version i values-fil
      VALUES_FILE="/etc/saasplatform/values/${ns}.yaml"
      if [[ -f "$VALUES_FILE" ]]; then
        yq eval ".image.tag = \"$NEW_VERSION\"" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"
      fi
      
      # Kør refresh
      if SELLYOURSAAS_INSTANCE_NAME="$CONTRACT_ID" SELLYOURSAAS_VERSION="$NEW_VERSION" bash "$(dirname "$0")/refresh.sh" "$CONTRACT_ID"; then
        echo "  ✓ Tenant $ns opdateret"
      else
        echo "  ✗ Tenant $ns fejlede"
        FAILED=$((FAILED+1))
      fi
    done
    
    echo ""
    echo "Fuld rollout fuldført: $((SUCCESS + ${#REMAINING_TENANTS[@]} - FAILED)) success, $FAILED failed"
  else
    echo ""
    echo "⚠️  Canary tenants ikke alle sunde - afbryder fuld rollout"
    exit 1
  fi
else
  echo ""
  echo "❌ Canary-rollout fejlede - $FAILED tenants"
  exit 1
fi

echo ""
echo "✅ Canary-rollout fuldført"
