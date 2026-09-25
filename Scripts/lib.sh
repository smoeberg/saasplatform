#!/usr/bin/env bash
# lib.sh — fælles funktioner for alle SellYourSaaS "kubernetes"-package remote-action scripts.
# Alle 8 scripts starter med: source "$(dirname "$0")/lib.sh" "$@"
#
# ANTAGELSE DER SKAL VERIFICERES mod jeres faktiske SellYourSaaS-installation:
# Dette lib antager at agenten kalder scriptet med contract-id som positionsparameter $1.
# Hvis jeres SellYourSaaS-version i stedet eksporterer det som miljøvariabel (fx
# $DOL_INSTANCE eller lignende — tjek DoliCloud's remote-action-dokumentation), så ret
# linjen "INSTANCE=..." nedenfor til at læse derfra i stedet. Se også README.md i denne
# mappe for den fulde liste af antagelser.

set -euo pipefail

# ---- Konfiguration (overstyres via miljøvariabler på K8s-runneren, §3.7) ----
KUBECONFIG="${KUBECONFIG:-/etc/saasplatform/kubeconfig}"
CHART_DIR="${CHART_DIR:-/opt/saasplatform/Helm/erp-tenant}"
VALUES_DIR="${VALUES_DIR:-/etc/saasplatform/values}"
STATUS_DIR="${STATUS_DIR:-/var/lib/saasplatform/status}"
TENANT_DOMAIN="${TENANT_DOMAIN:-tenants.example.com}"   # ANTAGELSE: ret til jeres faktiske DNS-skema
HEALTHZ_TIMEOUT="${HEALTHZ_TIMEOUT:-180}"                # sekunder at vente på grønt healthz
HEALTHZ_INTERVAL=5

export KUBECONFIG

# ---- Instans-id ----
INSTANCE="${1:?Mangler contract-id som argument 1 (se ANTAGELSE øverst i lib.sh)}"

# Sanitize: kun a-z, 0-9, bindestreg — undgår ugyldige K8s-navne / injection via navnet
if [[ ! "$INSTANCE" =~ ^[a-z0-9-]+$ ]]; then
  echo "FATAL: INSTANCE '$INSTANCE' indeholder ugyldige tegn (kun a-z, 0-9, -)" >&2
  exit 2
fi

NAMESPACE="tenant-${INSTANCE}"
RELEASE="tenant-${INSTANCE}"
VALUES_FILE="${VALUES_DIR}/${NAMESPACE}.yaml"
STATUS_FILE="${STATUS_DIR}/${NAMESPACE}.status"

mkdir -p "$STATUS_DIR"

# ---- Logging: journald (+ evt. fjernt syslog via logger-relæ, §3.7) ----
log() {
  local level="$1"; shift
  local msg="[$NAMESPACE] $*"
  logger -t saasplatform-k8s -p "user.${level}" "$msg" 2>/dev/null || true
  echo "$(date -Is) [$level] $msg"
}

fail() {
  log "err" "$*"
  exit 1
}

trap 'log "err" "Script fejlede ved linje $LINENO (exit-kode $?)"' ERR

# ---- Helpers ----
require_values_file() {
  [[ -f "$VALUES_FILE" ]] || fail "Values-fil mangler: $VALUES_FILE (skal være renderet af SellYourSaaS' config-template før scriptet kaldes)"
}

namespace_exists() {
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1
}

release_exists() {
  helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1
}

tenant_healthz_url() {
  echo "https://${INSTANCE}.${TENANT_DOMAIN}/healthz"
}

wait_for_healthz() {
  local url="$1"
  local waited=0
  log "info" "Venter på 200 fra $url (timeout ${HEALTHZ_TIMEOUT}s)"
  until curl -fsS -o /dev/null -m 5 "$url"; do
    sleep "$HEALTHZ_INTERVAL"
    waited=$((waited + HEALTHZ_INTERVAL))
    if (( waited >= HEALTHZ_TIMEOUT )); then
      fail "Healthz aldrig grøn efter ${HEALTHZ_TIMEOUT}s: $url"
    fi
  done
  log "info" "Healthz OK efter ${waited}s"
}

write_status() {
  echo "$1" > "$STATUS_FILE"
  log "info" "Status skrevet: $1 -> $STATUS_FILE"
}
