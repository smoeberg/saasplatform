#!/usr/bin/env bash
# beforeundeploy.sh — sikkerhedsnet før permanent nedlæggelse: tager et sidste DB-dump
# uden for den normale backup-rotation, adskilt fra retention-vinduet i §3.3 (som styres
# af Dolibarr/SellYourSaaS selv — dette script kaldes først når de har besluttet undeploy).

source "$(dirname "$0")/lib.sh" "$@"

if ! release_exists; then
  log "warn" "Release $RELEASE findes ikke — intet at sikkerhedskopiere, fortsætter"
  exit 0
fi

DUMP_DIR="${DUMP_DIR:-/var/backups/saasplatform/pre-undeploy}"
mkdir -p "$DUMP_DIR"
DUMP_FILE="${DUMP_DIR}/${NAMESPACE}-$(date +%Y%m%d%H%M%S).sql.gz"

# ANTAGELSE: DB-pod'en er labelet app.kubernetes.io/component=db i Helm-charten.
DB_POD="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=db \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$DB_POD" ]]; then
  log "warn" "Fandt ingen DB-pod i $NAMESPACE (label app.kubernetes.io/component=db) — springer dump over"
  exit 0
fi

log "info" "Dumper DB fra $DB_POD til $DUMP_FILE før undeploy"
kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  sh -c 'mysqldump --single-transaction --all-databases' | gzip > "$DUMP_FILE"

log "info" "Sikkerhedsdump gemt: $DUMP_FILE"
write_status "preundeploy-backup-ok"
