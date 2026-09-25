#!/bin/bash
# CI-harness: kør de 8 remote actions mod et k3d-cluster og verificér side-effects.
set -euo pipefail
NS="tenant-test1"
CHART="${SAAS_CHART_DIR:-./chart}"
PASS=0; FAIL=0

expect() { # expect <beskrivelse> <kommando> [<verificering>]
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; PASS=$((PASS+1)); else echo "FAIL: $desc"; FAIL=$((FAIL+1)); fi
}
k8s() { kubectl -n "$NS" "$@"; }
export SELLYOURSAAS_INSTANCE_NAME=test1
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://test1.kunder.saasplatform.dk"
export SAAS_CHART_DIR="$CHART"

echo "== deploy =="
expect "deploy lykkes" bash scripts/deploy.sh
expect "namespace findes" kubectl get ns "$NS"
expect "pods kører" bash -c "k8s wait --for=condition=available deploy/dolibarr --timeout=5m"
expect "mariadb kører" bash -c "k8s get sts mariadb -o jsonpath='{.spec.replicas}' | grep -q 1"

echo "== idempotens: deploy igen =="
expect "deploy (igen) lykkes" bash scripts/deploy.sh

echo "== suspend =="
expect "suspend lykkes" bash scripts/suspend.sh
expect "dolibarr replicas=0" bash -c "[ \"\$(k8s get deploy dolibarr -o jsonpath='{.spec.replicas}')\" = '0' ]"
expect "PVC bevaret" bash -c "k8s get pvc documents"

echo "== unsuspend =="
expect "unsuspend lykkes" bash scripts/unsuspend.sh
expect "dolibarr replicas=1" bash -c "[ \"\$(k8s get deploy dolibarr -o jsonpath='{.spec.replicas}')\" = '1' ]"

echo "== refresh =="
expect "refresh lykkes" bash scripts/refresh.sh

echo "== recreateauthorizedkeys =="
expect "rotate lykkes" bash scripts/recreateauthorizedkeys.sh
expect "secret findes" bash -c "k8s get secret platform-access"

echo "== undeploy =="
expect "undeploy lykkes" bash scripts/undeploy.sh
expect "namespace slettet" bash -c "! kubectl get ns \"$NS\" 2>/dev/null"

echo
echo "Resultat: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
