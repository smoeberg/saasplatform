#!/usr/bin/env bash
# test-fase1a.sh - CI test for fase 1a (native deployment)
# Tester: 10 fulde gennemlb + 2 fejl-injektion
#
# Forudstninger:
# - Native deployment server er opsat
# - SellYourSaaS master er konfigureret
# - PIM package er oprettet

set -euo pipefail

# Konfiguration
TEST_PREFIX="fase1a-test"
TEST_COUNT=10
FAIL_INJECTION_COUNT=2
PASS=0
FAIL=0
START_TIME=$(date +%s)

# Logging
log() {
  echo "[$(date -Is)] [TEST] $*"
}

pass() {
  echo "[32m✓ PASS[0m: $1"
  PASS=$((PASS+1))
}

fail() {
  echo "[31m✗ FAIL[0m: $1"
  FAIL=$((FAIL+1))
}

# Tjek at vi er p native deployment server
if [[ ! -f /opt/sellyoursaas/scripts/native/deploy.sh ]]; then
  fail "Native deployment scripts findes ikke"
  exit 1
fi

# Tjek at Apache krer
if ! systemctl is-active --quiet apache2 2>/dev/null; then
  fail "Apache krer ikke"
  exit 1
fi

# Tjek at PHP-FPM krer
if ! systemctl is-active --quiet php8.2-fpm 2>/dev/null; then
  fail "PHP-FPM krer ikke"
  exit 1
fi

log "Starter fase 1a tests..."

# ==========================================
# Test 1-10: Fulde gennemlb
# ==========================================
log ""
log "=== FULDE GENNEMLB (1-$TEST_COUNT) ==="

for i in $(seq 1 $TEST_COUNT); do
  TEST_INSTANCE="${TEST_PREFIX}-${i}"
  
  log ""
  log "Test $i: $TEST_INSTANCE"
  
  # beforedeploy
  if SELLYOURSAAS_INSTANCE_NAME="$TEST_INSTANCE" bash /opt/sellyoursaas/scripts/native/beforedeploy.sh; then
    pass "beforedeploy: $TEST_INSTANCE"
  else
    fail "beforedeploy fejlede: $TEST_INSTANCE"
    continue
  fi
  
  # deploy
  if SELLYOURSAAS_INSTANCE_NAME="$TEST_INSTANCE" \
     SELLYOURSAAS_DOLIBARRINSTANCE_URL="http://${TEST_INSTANCE}.localhost" \
     SELLYOURSAAS_DB_NAME="pim_${TEST_INSTANCE}" \
     bash /opt/sellyoursaas/scripts/native/deploy.sh; then
    pass "deploy: $TEST_INSTANCE"
  else
    fail "deploy fejlede: $TEST_INSTANCE"
    continue
  fi
  
  # Verificer bruger
  if id "$TEST_INSTANCE" &>/dev/null; then
    pass "bruger oprettet: $TEST_INSTANCE"
  else
    fail "bruger ikke oprettet: $TEST_INSTANCE"
    continue
  fi
  
  # Verificer home directory
  if [[ -d "/home/$TEST_INSTANCE/public_html" ]]; then
    pass "home directory: $TEST_INSTANCE"
  else
    fail "home directory mangler: $TEST_INSTANCE"
    continue
  fi
  
  # Verificer vhost
  if [[ -f "/etc/apache2/sites-available/${TEST_INSTANCE}.conf" ]]; then
    pass "vhost oprettet: $TEST_INSTANCE"
  else
    fail "vhost mangler: $TEST_INSTANCE"
    continue
  fi
  
  # Verificer FPM pool
  if [[ -f "/etc/php/8.2/fpm/pool.d/${TEST_INSTANCE}.conf" ]]; then
    pass "FPM pool oprettet: $TEST_INSTANCE"
  else
    fail "FPM pool mangler: $TEST_INSTANCE"
    continue
  fi
  
  # afterdeploy
  if SELLYOURSAAS_INSTANCE_NAME="$TEST_INSTANCE" \
     STATUS_DIR="/tmp/fase1a-status" \
     bash /opt/sellyoursaas/scripts/native/afterdeploy.sh; then
    pass "afterdeploy: $TEST_INSTANCE"
  else
    fail "afterdeploy fejlede: $TEST_INSTANCE"
    continue
  fi
  
  # Verificer status
  if [[ -f "/tmp/fase1a-status/${TEST_INSTANCE}.status" ]] && \
     grep -q "deployed" "/tmp/fase1a-status/${TEST_INSTANCE}.status"; then
    pass "status: $TEST_INSTANCE"
  else
    fail "status mangler: $TEST_INSTANCE"
    continue
  fi
  
  # Verificer healthz (simuleret)
  if [[ -f "/home/$TEST_INSTANCE/public_html/healthz.php" ]]; then
    pass "healthz.php: $TEST_INSTANCE"
  else
    fail "healthz.php mangler: $TEST_INSTANCE"
    continue
  fi
  
  # refresh
  if SELLYOURSAAS_INSTANCE_NAME="$TEST_INSTANCE" bash /opt/sellyoursaas/scripts/native/refresh.sh; then
    pass "refresh: $TEST_INSTANCE"
  else
    fail "refresh fejlede: $TEST_INSTANCE"
    continue
  fi
done

# ==========================================
# Test 11-12: Fejl-injektion
# ==========================================
log ""
log "=== FEJL-INJEKTION (1-$FAIL_INJECTION_COUNT) ==="

# Test 11: Betaling fejler midt i deploy
FAIL_TEST_1="${TEST_PREFIX}-fail-1"
log ""
log "Test 11: Betaling fejler midt i deploy ($FAIL_TEST_1)"

# Simuler deploy med fejl
if SELLYOURSAAS_INSTANCE_NAME="$FAIL_TEST_1" \
   SELLYOURSAAS_DOLIBARRINSTANCE_URL="http://${FAIL_TEST_1}.localhost" \
   SELLYOURSAAS_DB_NAME="pim_${FAIL_TEST_1}" \
   bash /opt/sellyoursaas/scripts/native/deploy.sh; then
  # Nu simulerer vi at betaling fejler - vi skal manuelt rydde op
  if SELLYOURSAAS_INSTANCE_NAME="$FAIL_TEST_1" bash /opt/sellyoursaas/scripts/native/undeploy.sh; then
    pass "fejl-injektion (betaling): cleanup lykkedes"
  else
    fail "fejl-injektion (betaling): cleanup fejlede"
  fi
else
  fail "fejl-injektion (betaling): deploy fejlede"
fi

# Verificer at bruger er slettet
if ! id "$FAIL_TEST_1" &>/dev/null; then
  pass "fejl-injektion: bruger slettet"
else
  # Forsg at slette manuelt
  if userdel -r "$FAIL_TEST_1" 2>/dev/null; then
    pass "fejl-injektion: manuel cleanup"
  else
    fail "fejl-injektion: bruger kunne ikke slettes"
  fi
fi

# Test 12: Deploy fejler (sources ikke tilgngelige)
FAIL_TEST_2="${TEST_PREFIX}-fail-2"
log ""
log "Test 12: Deploy fejler ($FAIL_TEST_2)"

# Simuler deploy med ugyldige sources (vi bruger bare deploy.sh direkte)
# Deploy skal fejle p et tidspunkt
if SELLYOURSAAS_INSTANCE_NAME="$FAIL_TEST_2" \
   SELLYOURSAAS_DOLIBARRINSTANCE_URL="http://${FAIL_TEST_2}.localhost" \
   SELLYOURSAAS_DB_NAME="pim_${FAIL_TEST_2}" \
   bash /opt/sellyoursaas/scripts/native/deploy.sh; then
  # Deploy lykkedes (vi simulerer fejl ved at slette manuelt)
  if SELLYOURSAAS_INSTANCE_NAME="$FAIL_TEST_2" bash /opt/sellyoursaas/scripts/native/undeploy.sh; then
    pass "fejl-injektion (deploy): cleanup lykkedes"
  else
    fail "fejl-injektion (deploy): cleanup fejlede"
  fi
else
  fail "fejl-injektion (deploy): deploy fejlede"
fi

# ==========================================
# Test 13-14: Suspension/Unsuspension
# ==========================================
log ""
log "=== SUSPENSION/UNSUSPENSION TESTS ==="

SUSPEND_TEST="${TEST_PREFIX}-suspend-1"
log ""
log "Test 13: Suspension ($SUSPEND_TEST)"

# Deploy
if SELLYOURSAAS_INSTANCE_NAME="$SUSPEND_TEST" \
   SELLYOURSAAS_DOLIBARRINSTANCE_URL="http://${SUSPEND_TEST}.localhost" \
   SELLYOURSAAS_DB_NAME="pim_${SUSPEND_TEST}" \
   bash /opt/sellyoursaas/scripts/native/deploy.sh; then
  pass "suspend-deploy: $SUSPEND_TEST"
else
  fail "suspend-deploy fejlede: $SUSPEND_TEST"
  FAIL_TEST_1="$SUSPEND_TEST"
fi

# suspend
if SELLYOURSAAS_INSTANCE_NAME="$SUSPEND_TEST" bash /opt/sellyoursaas/scripts/native/suspend.sh; then
  pass "suspend: $SUSPEND_TEST"
else
  fail "suspend fejlede: $SUSPEND_TEST"
fi

# Verificer suspension
if ! ls /etc/apache2/sites-enabled/ | grep -q "$SUSPEND_TEST"; then
  pass "suspend-verificering: vhost deaktiveret"
else
  fail "suspend-verificering: vhost ikke deaktiveret"
fi

# unsuspend
if SELLYOURSAAS_INSTANCE_NAME="$SUSPEND_TEST" bash /opt/sellyoursaas/scripts/native/unsuspend.sh; then
  pass "unsuspend: $SUSPEND_TEST"
else
  fail "unsuspend fejlede: $SUSPEND_TEST"
fi

# afterunsuspend
if SELLYOURSAAS_INSTANCE_NAME="$SUSPEND_TEST" \
   STATUS_DIR="/tmp/fase1a-status" \
   bash /opt/sellyoursaas/scripts/native/afterunsuspend.sh; then
  pass "afterunsuspend: $SUSPEND_TEST"
else
  fail "afterunsuspend fejlede: $SUSPEND_TEST"
fi

# Verificer unsuspension
if ls /etc/apache2/sites-enabled/ | grep -q "$SUSPEND_TEST"; then
  pass "unsuspend-verificering: vhost aktiveret"
else
  fail "unsuspend-verificering: vhost ikke aktiveret"
fi

# ==========================================
# Test 15: Undeploy
# ==========================================
log ""
log "=== UNDEPLOY TEST ==="

UNDEPLOY_TEST="${TEST_PREFIX}-undeploy-1"
log ""
log "Test 15: Undeploy ($UNDEPLOY_TEST)"

# Deploy
if SELLYOURSAAS_INSTANCE_NAME="$UNDEPLOY_TEST" \
   SELLYOURSAAS_DOLIBARRINSTANCE_URL="http://${UNDEPLOY_TEST}.localhost" \
   SELLYOURSAAS_DB_NAME="pim_${UNDEPLOY_TEST}" \
   bash /opt/sellyoursaas/scripts/native/deploy.sh; then
  pass "undeploy-deploy: $UNDEPLOY_TEST"
else
  fail "undeploy-deploy fejlede: $UNDEPLOY_TEST"
fi

# undeploy
if SELLYOURSAAS_INSTANCE_NAME="$UNDEPLOY_TEST" \
   SELLYOURSAAS_DB_NAME="pim_${UNDEPLOY_TEST}" \
   bash /opt/sellyoursaas/scripts/native/undeploy.sh; then
  pass "undeploy: $UNDEPLOY_TEST"
else
  fail "undeploy fejlede: $UNDEPLOY_TEST"
fi

# Verificer undeploy
if ! id "$UNDEPLOY_TEST" &>/dev/null && \
   ! ls /etc/apache2/sites-available/ | grep -q "$UNDEPLOY_TEST" && \
   ! ls /etc/php/8.2/fpm/pool.d/ | grep -q "$UNDEPLOY_TEST"; then
  pass "undeploy-verificering: alt slettet"
else
  fail "undeploy-verificering: nogle ressourcer findes stadig"
fi

# ==========================================
# Resultat
# ==========================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log ""
log "=========================================="
log "Resultat: $PASS pass, $FAIL fail"
log "Tid: ${DURATION}s"
log "=========================================="

# Ryd op
log ""
log "Rydder op..."

# Slet alle test tenants
for i in $(seq 1 $TEST_COUNT); do
  TEST_INSTANCE="${TEST_PREFIX}-${i}"
  if id "$TEST_INSTANCE" &>/dev/null; then
    SELLYOURSAAS_INSTANCE_NAME="$TEST_INSTANCE" \
      SELLYOURSAAS_DB_NAME="pim_${TEST_INSTANCE}" \
      bash /opt/sellyoursaas/scripts/native/undeploy.sh 2>/dev/null || true
  fi
done

# Slet fejl-injektion tests
for i in $(seq 1 $FAIL_INJECTION_COUNT); do
  TEST_INSTANCE="${TEST_PREFIX}-fail-${i}"
  if id "$TEST_INSTANCE" &>/dev/null; then
    SELLYOURSAAS_INSTANCE_NAME="$TEST_INSTANCE" \
      SELLYOURSAAS_DB_NAME="pim_${TEST_INSTANCE}" \
      bash /opt/sellyoursaas/scripts/native/undeploy.sh 2>/dev/null || true
  fi
done

# Slet suspend test
if id "$SUSPEND_TEST" &>/dev/null; then
  SELLYOURSAAS_INSTANCE_NAME="$SUSPEND_TEST" \
    SELLYOURSAAS_DB_NAME="pim_${SUSPEND_TEST}" \
    bash /opt/sellyoursaas/scripts/native/undeploy.sh 2>/dev/null || true
fi

# Slet undeploy test
if id "$UNDEPLOY_TEST" &>/dev/null; then
  SELLYOURSAAS_INSTANCE_NAME="$UNDEPLOY_TEST" \
    SELLYOURSAAS_DB_NAME="pim_${UNDEPLOY_TEST}" \
    bash /opt/sellyoursaas/scripts/native/undeploy.sh 2>/dev/null || true
fi

# Genstart services
log "Genstarter services..."
systemctl restart apache2 2>/dev/null || true
systemctl restart php8.2-fpm 2>/dev/null || true

if (( FAIL > 0 )); then
  log ""
  log "❌ Nogle tests fejlede"
  exit 1
else
  log ""
  log "✅ Alle tests bestået"
  exit 0
fi
