#!/usr/bin/env bash
# lib.sh — fælles funktioner for alle SellYourSaaS "kubernetes"-package remote-action scripts.
# Alle 8 scripts starter med: source "$(dirname "$0")/lib.sh" "$@"
#
# ANTAGELSE DER SKAL VERIFICERES mod jeres faktiske SellYourSaaS-installation:
# Dette lib antager at agenten kalder scriptet med contract-id som positionsparameter $1.
# Hvis jeres SellYourSaaS-version i stedet eksporterer det som miljøvariabel (fx
# $SELLYOURSAAS_INSTANCE_NAME eller lignende — tjek DoliCloud's remote-action-dokumentation), 
# så vil scriptet bruge miljøvariablen som fallback.
# Se også README.md i denne mappe for den fulde liste af antagelser.

set -euo pipefail

# ---- Konfiguration (overstyres via miljøvariabler på K8s-runneren, §3.7) ----
KUBECONFIG="${KUBECONFIG:-/etc/saasplatform/kubeconfig}"
CHART_DIR="${CHART_DIR:-/opt/saasplatform/Helm}"
VALUES_DIR="${VALUES_DIR:-/etc/saasplatform/values}"
STATUS_DIR="${STATUS_DIR:-/var/lib/saasplatform/status}"
TENANT_DOMAIN="${TENANT_DOMAIN:-tenants.example.com}"   # ANTAGELSE: ret til jeres faktiske DNS-skema
HEALTHZ_TIMEOUT="${HEALTHZ_TIMEOUT:-180}"                # sekunder at vente på grønt healthz
HEALTHZ_INTERVAL=5
DUMP_DIR="${DUMP_DIR:-/var/backups/saasplatform/pre-undeploy}"

# S3/Backup konfiguration
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"

# DNS konfiguration (Cloudflare)
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"

# SealedSecrets konfiguration
KUBESEAL_CERT="${KUBESEAL_CERT:-/etc/saasplatform/kubeseal-cert.pem}"

export KUBECONFIG

# ---- Instans-id ----
# Prøv positionsparameter $1 først, derefter miljøvariabler
if [[ $# -ge 1 && -n "$1" ]]; then
  INSTANCE="$1"
elif [[ -n "${SELLYOURSAAS_INSTANCE_NAME:-}" ]]; then
  INSTANCE="$SELLYOURSAAS_INSTANCE_NAME"
elif [[ -n "${SELLYOURSAAS_CONTRACT_ID:-}" ]]; then
  INSTANCE="$SELLYOURSAAS_CONTRACT_ID"
else
  echo "FATAL: Mangler contract-id som argument 1 eller som miljøvariabel (SELLYOURSAAS_INSTANCE_NAME eller SELLYOURSAAS_CONTRACT_ID)" >&2
  exit 2
fi

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
mkdir -p "$DUMP_DIR"

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

# ---- DNS Helpers (Cloudflare) ----
dns_create() {
  local ns="$1"
  local domain="${ns#tenant-}.${TENANT_DOMAIN}"
  
  if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
    log "warn" "Cloudflare API token eller zone ID ikke konfigureret - springer DNS-oprettelse over"
    return 0
  fi
  
  # Opret A-record for tenant-domain
  local record_id
  record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${domain}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  
  if [[ -n "$record_id" ]]; then
    log "info" "DNS-record for ${domain} findes allerede (ID: ${record_id})"
    return 0
  fi
  
  # Opret ny record
  local ip
  ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
       kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
       echo "${CLOUDFLARE_INGRESS_IP:-}")
  
  if [[ -z "$ip" ]]; then
    log "warn" "Kunne ikke bestemme ingress-IP - springer DNS-oprettelse over"
    return 0
  fi
  
  local response
  response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"A\",\"name\":\"${domain}\",\"content\":\"${ip}\",\"ttl\":300,\"proxied\":false}")
  
  local success
  success=$(echo "$response" | jq -r '.success // false')
  
  if [[ "$success" == "true" ]]; then
    log "info" "DNS-record oprettet: ${domain} -> ${ip}"
    
    # Vent på propagation (max 10 minutter)
    local waited=0
    while ! dig +short "${domain}" | grep -q "${ip}"; do
      sleep 10
      waited=$((waited + 10))
      if (( waited >= 600 )); then
        log "warn" "DNS propagation timeout for ${domain}"
        break
      fi
    done
    log "info" "DNS propagation bekræftet for ${domain}"
  else
    log "err" "DNS-record oprettelse fejlede for ${domain}: $(echo "$response" | jq -r '.errors[0].message // "ukendt fejl")"
    return 1
  fi
}

dns_delete() {
  local ns="$1"
  local domain="${ns#tenant-}.${TENANT_DOMAIN}"
  
  if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
    log "warn" "Cloudflare API token eller zone ID ikke konfigureret - springer DNS-sletning over"
    return 0
  fi
  
  # Find og slet record
  local record_id
  record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${domain}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  
  if [[ -z "$record_id" ]]; then
    log "info" "DNS-record for ${domain} findes ikke - intet at slette"
    return 0
  fi
  
  local response
  response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json")
  
  local success
  success=$(echo "$response" | jq -r '.success // false')
  
  if [[ "$success" == "true" ]]; then
    log "info" "DNS-record slettet: ${domain}"
  else
    log "err" "DNS-record sletning fejlede for ${domain}: $(echo "$response" | jq -r '.errors[0].message // "ukendt fejl")"
    return 1
  fi
}

# ---- S3/Backup Helpers ----
s3_upload() {
  local file="$1"
  local dest="$2"
  
  if [[ -z "$S3_ENDPOINT" || -z "$S3_BUCKET" || -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
    log "warn" "S3 konfiguration ikke fuldstændig - springer upload over"
    return 0
  fi
  
  if [[ ! -f "$file" ]]; then
    log "err" "Fil findes ikke: $file"
    return 1
  fi
  
  # Upload til S3 (Wasabi/Mino)
  local url="${S3_ENDPOINT}/${S3_BUCKET}/${dest}"
  
  if curl -s -X PUT -T "$file" "$url" \
    -H "Host: ${S3_BUCKET}.${S3_ENDPOINT#*//}" \
    -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}"; then
    log "info" "S3 upload: $file -> $url"
    return 0
  else
    log "err" "S3 upload fejlede: $file -> $url"
    return 1
  fi
}

# ---- SealedSecrets Helpers ----
create_sealed_secret() {
  local name="$1"
  local namespace="$2"
  shift 2
  local literals=("$@")
  
  if [[ ! -f "$KUBESEAL_CERT" ]]; then
    log "warn" "kubeseal cert ikke fundet: $KUBESEAL_CERT - springer SealedSecret over"
    return 0
  fi
  
  # Opret klartekst secret
  local temp_file=$(mktemp)
  kubectl create secret generic "$name" -n "$namespace" \
    $(for lit in "${literals[@]}"; do echo -n "--from-literal=$lit "; done) \
    --dry-run=client -o yaml > "$temp_file"
  
  # Konverter til SealedSecret
  local sealed_file=$(mktemp)
  kubeseal --cert "$KUBESEAL_CERT" --format yaml < "$temp_file" > "$sealed_file"
  
  # Apply SealedSecret
  kubectl apply -f "$sealed_file" -n "$namespace"
  
  # Slet klartekst
  rm -f "$temp_file" "$sealed_file"
  
  log "info" "SealedSecret oprettet: $namespace/$name"
}

# ---- Namespace resolution (extrafields) ----
resolve_namespace() {
  # Prøv at læse fra extrafields i Dolibarr (via API)
  # For nu: brug standard mapping
  echo "tenant-${INSTANCE}"
}
