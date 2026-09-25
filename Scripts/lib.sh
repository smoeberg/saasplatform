#!/bin/bash
# Fælles lib for alle remote-action-scripts. Kildes: source "$(dirname "$0")/lib.sh"
set -euo pipefail

# --- Logging ---
log()  { echo "[$(date -u +%FT%TZ)] [${SELLYOURSAAS_INSTANCE_NAME:-?}] $*" >&2; }
fail() { log "FEJL: $*"; exit 1; }

# --- Namespace-mapping (Arkitektur §3.3.1) ---
# Læs k8s_namespace extrafield fra SellYourSaaS (via agent-env/dolibarr REST),
# fallback: generér tenant-{contract-id} og skriv tilbage til extrafield.
# SELLYOURSAAS_CONTRACT_ID og SELLYOURSAAS_EXTRAFIELD_API sættes af wrapperen.
resolve_namespace() {
  local contract="${SELLYOURSAAS_CONTRACT_ID:?}"
  local ns
  ns="${SELLYOURSAAS_K8S_NAMESPACE:-}"
  if [ -z "$ns" ]; then
    ns="tenant-${contract}"
    log "extrafield tomt → genererer namespace: $ns"
    set_extrafield k8s_namespace "$ns"
  fi
  if [ "$ns" != "tenant-${contract}" ]; then
    log "ADVARSEL: k8s_namespace ('$ns') matcher ikke tenant-${contract} — respekterer manuel override"
  fi
  echo "$ns"
}

set_extrafield() {
  local field="$1" value="$2"
  if [ -n "${SELLYOURSAAS_EXTRAFIELD_API:-}" ]; then
    curl -sf -X POST "$SELLYOURSAAS_EXTRAFIELD_API" \
      -H "Authorization: Bearer $SELLYOURSAAS_API_TOKEN" \
      -d "{\"contract\": \"${SELLYOURSAAS_CONTRACT_ID}\", \"field\": \"$field\", \"value\": \"$value\"}" \
      >/dev/null || fail "kunne ikke gemme extrafield $field"
  else
    log "ADVARSEL: ingen EXTRAFIELD_API — extrafield $field gemmes ikke (dev)"
  fi
}

# --- Secrets (Arkitektur §3.3.1: generér lokalt → SealedSecret → slet klartekst) ---
ensure_secrets() {
  local ns="$1"
  if kubectl -n "$ns" get secret tenant-db >/dev/null 2>&1; then
    log "secret tenant-db findes allerede"
    return
  fi
  command -v kubeseal >/dev/null || fail "kubeseal mangler på runneren"
  local pw rp
  pw="$(openssl rand -base64 32)"
  rp="$(openssl rand -base64 32)"
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  kubectl -n "$ns" create secret generic tenant-db \
    --from-literal=username=dolibarr \
    --from-literal=password="$pw" \
    --from-literal=root_password="$rp" \
    --dry-run=client -o yaml > "$tmp"
  kubeseal -f "$tmp" -o yaml | kubectl apply -f -
  rm -f "$tmp"   # klartekst slettes straks
  unset pw rp    # fjern variabler
  log "SealedSecret tenant-db oprettet i $ns"
}

# --- DNS (Cloudflare, Arkitektur §5 fase 1b) ---
dns_create() {
  local ns="$1" domain="${SELLYOURSAAS_DOLIBARRINSTANCE_URL:?}"
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { log "ADVARSEL: ingen CLOUDFLARE_API_TOKEN — DNS ikke automatiseret (dev)"; return; }
  local zone="kunder.saasplatform.dk"   # TODO: pr. setup
  local rec="${domain%%.$zone}"
  curl -sf -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"A\",\"name\":\"${rec}\",\"content\":\"${CLOUDFLARE_INGRESS_IP:?}\",\"ttl\":300}" \
    >/dev/null || fail "kunne ikke oprette DNS-record"
  log "DNS-record oprettet: $domain → $CLOUDFLARE_INGRESS_IP"
}

dns_delete() {
  local domain="${SELLYOURSAAS_DOLIBARRINSTANCE_URL:?}"
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || return 0
  local zone="kunder.saasplatform.dk"
  local rec="${domain%%.$zone}"
  local id
  id=$(curl -sf "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${domain}" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -r '.result[0].id // empty')
  [ -n "$id" ] && curl -sf -X DELETE "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/$id" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" >/dev/null
  log "DNS-record slettet: $domain"
}
