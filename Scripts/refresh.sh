#!/bin/bash
# SellYourSaaS action: refresh — re-apply ønsketilstand (idempotent converge)
set -euo pipefail
helm upgrade --install tenant "${SAAS_CHART_DIR:?}/dolibarr" \
  -n "tenant-${SELLYOURSAAS_INSTANCE_NAME:?}" --reuse-values --wait
echo "refreshed ${SELLYOURSAAS_INSTANCE_NAME:?}"
