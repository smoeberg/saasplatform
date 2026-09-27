#!/usr/bin/env bash
# update-tenant.sh - Opdater en enkelt tenant til ny version
# Bruges af SellYourSaaS ved version-opdateringer

set -euo pipefail

source "$(dirname "$0")/lib.sh" "$@"

require_values_file

NEW_VERSION="${SELLYOURSAAS_VERSION:-}"
CURRENT_VERSION=$(helm get values "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.image.tag // ""' || echo "")

if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
  log "info" "Ingen versionsaendring - intet at gore"
  write_status "update-not-needed"
  exit 0
fi

log "info" "Opdaterer tenant $INSTANCE fra $CURRENT_VERSION til $NEW_VERSION"

# Tjek om dette er en migrerende version (DB aendring)
if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
  # Kor migrering (tager pre-migration snapshot)
  log "info" "Korer migrering..."
  if ! bash "$(dirname "$0")/migrate.sh" "$INSTANCE"; then
    fail "Migrering fejlede"
  fi
fi

# Opdater values-fil
log "info" "Opdaterer values-fil..."
yq eval ".image.tag = \"$NEW_VERSION\"" -i "$VALUES_FILE" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "$VALUES_FILE"

# Kor refresh (helm upgrade)
log "info" "Korer refresh..."
if ! bash "$(dirname "$0")/refresh.sh" "$INSTANCE"; then
  # Forsog rollback
  log "err" "Opdatering fejlede - forsoger rollback..."
  if ! bash "$(dirname "$0")/rollback.sh" "$INSTANCE"; then
    fail "Opdatering og rollback fejlede"
  fi
  fail "Opdatering fejlede, rollback lykkedes"
fi

write_status "updated"
log "info" "Tenant $INSTANCE opdateret til version $NEW_VERSION"
