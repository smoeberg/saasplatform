#!/usr/bin/env bash
# cron.sh - Ekstern sundhedstjek af tenant-URL'en, kaldt periodisk af SellYourSaaS'
# supervision (3.2, 3.6). Dette er IKKE runner-heartbeatet (det er en separat,
# uafhaengig cron paa selve runneren beskrevet i 3.7) - dette er pr.-tenant helbred.

source "$(dirname "$0")/lib.sh" "$@"

URL="$(tenant_healthz_url)"

# Fix: Suspenderede tenants besvares af nginx-suspended-page som ikke har /healthz
# Tjek om tenant er suspended foer healthz check
SUSPENDED=$(yq eval '.suspended // false' "$VALUES_FILE" 2>/dev/null || echo "false")

if [[ "$SUSPENDED" == "true" ]]; then
  # For suspended tenants: tjek at suspended-page er tilgangelig
  SUSPENDED_URL="https://${INSTANCE}.${TENANT_DOMAIN}/"
  if curl -fsS -o /dev/null -m 10 "$SUSPENDED_URL"; then
    write_status "healthy"
    log "info" "cron: $NAMESPACE er suspended, suspended-page svarer 200"
    exit 0
  else
    write_status "unhealthy"
    log "err" "cron: $NAMESPACE er suspended, men suspended-page svarer ikke"
    exit 1
  fi
fi

# Normal healthz check for ikke-suspenderede tenants
if curl -fsS -o /dev/null -m 10 "$URL"; then
  write_status "healthy"
  log "info" "cron: $URL svarer 200"
  exit 0
else
  write_status "unhealthy"
  log "err" "cron: $URL svarer ikke 200 - flag til SellYourSaaS' supervision"
  exit 1
fi
