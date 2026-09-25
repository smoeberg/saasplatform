#!/usr/bin/env bash
# cron.sh — ekstern sundhedstjek af tenant-URL'en, kaldt periodisk af SellYourSaaS'
# supervision (§3.2, §3.6). Dette er IKKE runner-heartbeatet (det er en separat,
# uafhængig cron på selve runneren beskrevet i §3.7) — dette er pr.-tenant helbred.

source "$(dirname "$0")/lib.sh" "$@"

URL="$(tenant_healthz_url)"

if curl -fsS -o /dev/null -m 10 "$URL"; then
  write_status "healthy"
  log "info" "cron: $URL svarer 200"
  exit 0
else
  write_status "unhealthy"
  log "err" "cron: $URL svarer ikke 200 — flag til SellYourSaaS' supervision"
  exit 1
fi
