#!/usr/bin/env bash
# beforedeploy.sh — pre-flight tjek før SellYourSaaS kalder afterdeploy.sh.
# Fejler (exit != 0) stopper hele deploy-flowet, før noget rammer produktion (§2.4 fail-closed).

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

# Values-filen skal kunne templates mod chartet uden fejl.
if ! helm template "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" -f "$VALUES_FILE" >/dev/null; then
  fail "Values-fil renderer ikke mod chartet ($CHART_DIR) — templating fejlede"
fi

# K8s-API skal være nåbart, og service-accounten skal have rettigheder i netop dette namespace.
kubectl auth can-i create deployments -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "Service-account mangler rettigheder i namespace $NAMESPACE (tjek RBAC, §3.7)"

if namespace_exists; then
  log "warn" "Namespace $NAMESPACE findes allerede — antager gen-deploy, fortsætter idempotent"
fi

write_status "predeploy-ok"
log "info" "beforedeploy: alle tjek bestået"
