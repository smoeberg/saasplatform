#!/usr/bin/env bash
# canary-check.sh - Tjek canary tenants status
# Bruges af canary-rollout.sh til at verificere tenant sundhed

set -euo pipefail

source "$(dirname "$0")/lib.sh" "$@"

# Tjek healthz endpoint
HEALTHZ_URL="$(tenant_healthz_url)"

if curl -fsS -o /dev/null -m 5 "$HEALTHZ_URL"; then
  echo "✓ Healthz OK"
  exit 0
else
  echo "✗ Healthz fejlede"
  exit 1
fi
