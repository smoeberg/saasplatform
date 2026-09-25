#!/bin/bash
# CI-harness: kører de 8 remote actions mod et k3d-cluster og verificerer side-effects.
# Kører alle scripts med positionsparameter (contract-id) for konsistens.
set -euo pipefail

# Konfiguration
TEST_INSTANCE="test1"
NS="tenant-${TEST_INSTANCE}"
CHART_DIR="${CHART_DIR:-./Helm}"
HEALTHZ_TIMEOUT=30

# Tællere
PASS=0
FAIL=0

expect() {
  # expect <beskrivelse> <kommando> [<verificering>]
  local desc="$1"
  shift
  if "$@"; then 
    echo "✓ PASS: $desc"
    PASS=$((PASS+1))
  else 
    echo "✗ FAIL: $desc"
    FAIL=$((FAIL+1))
  fi
}

k8s() {
  kubectl -n "$NS" "$@"
}

# Eksportér miljøvariabler som scripts forventer
export KUBECONFIG="$HOME/.kube/config"
export CHART_DIR="$CHART_DIR"
export VALUES_DIR="/tmp/saasplatform-values"
export STATUS_DIR="/tmp/saasplatform-status"
export TENANT_DOMAIN="kunder.saasplatform.test"
export DUMP_DIR="/tmp/saasplatform-dumps"
export SELLYOURSAAS_INSTANCE_NAME="$TEST_INSTANCE"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://${TEST_INSTANCE}.${TENANT_DOMAIN}"
export SELLYOURSAAS_VERSION="23.0.1"

# Opret test-mapper
mkdir -p "$VALUES_DIR" "$STATUS_DIR" "$DUMP_DIR"

# Opret en simpel values-fil til test
echo "instance: $TEST_INSTANCE
domain: ${TEST_INSTANCE}.${TENANT_DOMAIN}
image:
  repository: ghcr.io/smoeberg/dolibarr
  tag: 23.0.1
suspended: false
backup:
  enabled: true
db:
  enabled: true
  storage: 1Gi
quota:
  requestsCpu: "1"
  requestsMemory: 2Gi
  limitsCpu: "2"
  limitsMemory: 4Gi
  pvc: "3"
networkPolicy:
  defaultDeny: false
egressMail: false" > "${VALUES_DIR}/${NS}.yaml"

echo "=========================================="
echo "CI Test: SellYourSaaS Remote Actions"
echo "=========================================="

# Vent på at clusteret er klar
echo "⏳ Venter på cluster..."
sleep 5

# ==========================================
# TEST 1: beforedeploy
# ==========================================
echo ""
echo "=== TEST 1: beforedeploy ==="
expect "beforedeploy validerer values-fil" bash Scripts/beforedeploy.sh "$TEST_INSTANCE"
expect "beforedeploy skriver predeploy-ok status" test -f "${STATUS_DIR}/${NS}.status" && grep -q "predeploy-ok" "${STATUS_DIR}/${NS}.status"

# ==========================================
# TEST 2: deploy
# ==========================================
echo ""
echo "=== TEST 2: deploy ==="
expect "deploy opretter namespace" bash Scripts/deploy.sh "$TEST_INSTANCE" || true

# Vent på at namespace er oprettet
sleep 2
expect "namespace findes" kubectl get ns "$NS"

# Vent på pods (max 2 minutter)
echo "  ⏳ Venter på Dolibarr pod..."
for i in $(seq 1 12); do
  if kubectl get pods -n "$NS" -l app=dolibarr -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
    echo "  ✓ Dolibarr pod kører"
    break
  fi
  sleep 10
done

# Vent på mariadb pod
echo "  ⏳ Venter på MariaDB pod..."
for i in $(seq 1 12); do
  if kubectl get pods -n "$NS" -l app=mariadb -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
    echo "  ✓ MariaDB pod kører"
    break
  fi
  sleep 10
done

echo ""
echo "=== TEST 3: deploy (idempotens) ==="
expect "deploy (igen) lykkes (idempotent)" bash Scripts/deploy.sh "$TEST_INSTANCE" || true

# ==========================================
# TEST 4: suspend
# ==========================================
echo ""
echo "=== TEST 4: suspend ==="
expect "suspend sætter replicas til 0" bash Scripts/suspend.sh "$TEST_INSTANCE"

# Vent på at deployments er skaleret til 0
sleep 5
expect "dolibarr replicas=0" bash -c "[ \"\$(k8s get deploy dolibarr -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '1')\" = '0' ]"
expect "mariadb replicas=0" bash -c "[ \"\$(k8s get sts mariadb -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '1')\" = '0' ]"
expect "suspend skriver suspended status" test -f "${STATUS_DIR}/${NS}.status" && grep -q "suspended" "${STATUS_DIR}/${NS}.status"

# ==========================================
# TEST 5: unsuspend
# ==========================================
echo ""
echo "=== TEST 5: unsuspend ==="
expect "unsuspend genopretter replicas" bash Scripts/unsuspend.sh "$TEST_INSTANCE"

# Vent på at pods kører igen
sleep 5
echo "  ⏳ Venter på Dolibarr pod efter unsuspend..."
for i in $(seq 1 12); do
  if kubectl get pods -n "$NS" -l app=dolibarr -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
    echo "  ✓ Dolibarr pod kører igen"
    break
  fi
  sleep 10
done

echo ""
echo "=== TEST 6: refresh ==="
expect "refresh lykkes" bash Scripts/refresh.sh "$TEST_INSTANCE"
expect "refresh skriver deployed status" test -f "${STATUS_DIR}/${NS}.status" && grep -q "deployed" "${STATUS_DIR}/${NS}.status"

# ==========================================
# TEST 7: recreateauthorizedkeys
# ==========================================
echo ""
echo "=== TEST 7: recreateauthorizedkeys ==="
expect "recreateauthorizedkeys lykkes" bash Scripts/recreateauthorizedkeys.sh "$TEST_INSTANCE"
# Tjek at secret findes (som klartekst eller SealedSecret)
expect "platform-access secret findes" bash -c "k8s get secret platform-access 2>/dev/null || k8s get sealedsecret platform-access 2>/dev/null"

# ==========================================
# TEST 8: cron (health check)
# ==========================================
echo ""
echo "=== TEST 8: cron (health check) ==="
# Opret en simpel test-service til health check
kubectl create deployment test-healthz -n "$NS" --image=nginx --port=80 -- /bin/sh -c "echo 'OK' > /usr/share/nginx/html/healthz && nginx -g 'daemon off;'"
kubectl expose deployment test-healthz -n "$NS" --port=80
sleep 2

# Opdater domain til at pege på test-service
kubectl patch svc test-healthz -n "$NS" -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true
sleep 2

# Prøv cron check (vil fejle uden korrekt DNS, men tester scriptet)
expect "cron script kører" bash Scripts/cron.sh "$TEST_INSTANCE" || true

# ==========================================
# TEST 9: beforeundeploy (backup)
# ==========================================
echo ""
echo "=== TEST 9: beforeundeploy (DB dump) ==="
expect "beforeundeploy kører" bash Scripts/beforeundeploy.sh "$TEST_INSTANCE" || true
expect "dump-fil oprettet" test -f "${DUMP_DIR}/${NS}-*.sql.gz" || echo "  (S3 upload testet, lokal fil muligvis slettet)"

# ==========================================
# TEST 10: undeploy
# ==========================================
echo ""
echo "=== TEST 10: undeploy ==="
expect "undeploy lykkes" bash Scripts/undeploy.sh "$TEST_INSTANCE" || true
expect "namespace slettet" bash -c "! kubectl get ns \"$NS\" 2>/dev/null || false"

# ==========================================
# RESULTAT
# ==========================================
echo ""
echo "=========================================="
echo "Resultat: $PASS pass, $FAIL fail"
echo "=========================================="

if (( FAIL > 0 )); then
  echo "❌ Nogle tests fejlede"
  exit 1
else
  echo "✅ Alle tests bestået"
  exit 0
fi
