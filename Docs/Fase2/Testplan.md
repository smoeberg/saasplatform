# Fase 2 - Testplan: Produktionsdrift

## Formaal

Verificere at **produktionsdrifts-funktionalitet** fungerer korrekt:
- **Canary-rollout** (stratificeret + rotation)
- **Velero backup** med Wasabi S3
- **Observability stack** (Prometheus + Grafana + Loki)
- **Natlig DB-dump** for alle tenants
- **Produktionsmiljo** for begge deployment-typer

**Exit-kriterier:** Canary-rollout fungerer + Velero backup funktionel + Observability stack funktionel + CI-niveau 2 groen.

---

## Testmatrix

| ID | Test | Type | Exit-kriterium | Status | Noter | Kritisk |
|----|------|------|----------------|--------|-------|---------|
| 2-01 | Canary-rollout (standard plan) | Funktionel | Korrekt % canary tenants, healthz OK | [ ] | | Yes |
| 2-02 | Canary-rollout (premium plan) | Funktionel | Korrekt % canary tenants, healthz OK | [ ] | | Yes |
| 2-03 | Canary rotation | Funktionel | Rotationsindeks inkrementeret korrekt | [ ] | | Yes |
| 2-04 | Canary fejlhaandtering | Fejlhaandtering | Rollback ved healthz failure | [ ] | | Yes |
| 2-05 | Velero backup (alle tenants) | Funktionel | Backup koret, verificeret i S3 | [ ] | | Yes |
| 2-06 | Velero restore (tenant) | Funktionel | Restore koret, tenant fungerer | [ ] | | Yes |
| 2-07 | Natlig DB-dump | Funktionel | DB-dump koret, verificeret i S3 | [ ] | | Yes |
| 2-08 | Prometheus metrikker | Funktionel | Targets healthy, metrikker indsamlet | [ ] | | Yes |
| 2-09 | Grafana dashboards | Funktionel | Login fungerer, dashboards viser data | [ ] | | Yes |
| 2-10 | Loki logging | Funktionel | Logs indsamlet, queries fungerer | [ ] | | Yes |
| 2-11 | Alerts (tenant nedetid) | Funktionel | Alert triggeret og modtaget | [ ] | | Yes |
| 2-12 | Alerts (high CPU) | Funktionel | Alert triggeret ved high CPU | [ ] | | No |
| 2-13 | Alerts (certificate expiration) | Funktionel | Alert triggeret ved cert expiration | [ ] | | Yes |
| 2-14 | Produktionsmiljo (k3s) | Funktionel | Alle tenants deployet, healthz OK | [ ] | | Yes |
| 2-15 | Produktionsmiljo (native) | Funktionel | Native deployment fungerer | [ ] | | Yes |

---

## Forudsætninger

- [ ] Fase 1c er faerdig (livscyklus og gendannelse fungerer)
- [ ] k3s cluster koerer med Traefik, cert-manager, SealedSecrets
- [ ] K8s-runner VM er opsat
- [ ] Velero er installeret i clusteret
- [ ] Wasabi S3 er konfigureret
- [ ] Observability stack er installeret
- [ ] Canary-rollout scripts er konfigureret
- [ ] Test tenants er deployet

---

## Test Setup

### 1. Miljoevariabler

```bash
# Paa runner VM
export KUBECONFIG="/etc/saasplatform/kubeconfig"
export CHART_DIR="/opt/saasplatform/Helm/erp-tenant"
export VALUES_DIR="/etc/saasplatform/values"
export STATUS_DIR="/var/lib/saasplatform/status"
export TENANT_DOMAIN="kunder.saasplatform.dk"
export S3_ENDPOINT="https://s3.eu-central-1.wasabisys.com"
export S3_BUCKET="saasplatform-backups"

# Canary settings
export CANARY_PERCENTAGE=5
export CANARY_PERCENTAGE_PREMIUM=10
export CANARY_WINDOW=1800
```

### 2. Test Tenants

```bash
# Opret test tenants (standard plan)
for i in $(seq 1 20); do
  export SELLYOURSAAS_INSTANCE_NAME="canary-test-standard-${i}"
  export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://canary-test-standard-${i}.${TENANT_DOMAIN}"
  export SELLYOURSAAS_VERSION="23.0.1"
  export SELLYOURSAAS_PLAN="standard"
  ./Scripts/deploy.sh "canary-test-standard-${i}"
done

# Opret test tenants (premium plan)
for i in $(seq 1 10); do
  export SELLYOURSAAS_INSTANCE_NAME="canary-test-premium-${i}"
  export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://canary-test-premium-${i}.${TENANT_DOMAIN}"
  export SELLYOURSAAS_VERSION="23.0.1"
  export SELLYOURSAAS_PLAN="premium"
  ./Scripts/deploy.sh "canary-test-premium-${i}"
done

# Vent paa alle tenants er klar
sleep 300

# Verificer alle tenants
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  ./Scripts/cron.sh "${ns#tenant-}"
done
```

---

## Test Procedure

---

### Test 2-01: Canary-rollout (Standard Plan)

**Formaal:** Verificere at canary-rollout fungerer for standard plan tenants.

**Steps:**
1. Resetter rotationsindeks for standard plan
2. Koer canary-rollout med ny version
3. Verificer at korrekt antal canary tenants er valgt
4. Verificer at canary tenants har ny version
5. Verificer healthz checks for canary tenants

**Commands:**
```bash
# 1. Reset rotationsindeks
echo 0 > /var/lib/saasplatform/canary-index-standard-k8s-prod.txt

# 2. Koer canary-rollout
export SELLYOURSAAS_VERSION="23.0.2"
./Scripts/canary-rollout.sh

# 3. Verificer antal canary tenants (5% af 20 = 1 tenant)
CANARY_COUNT=$(kubectl get pods -A -l canary=true --no-headers | wc -l)
if [ "$CANARY_COUNT" -eq 1 ]; then
  echo "PASS: Korrekt antal canary tenants (1)"
else
  echo "FAIL: Forkert antal canary tenants (forventet 1, got $CANARY_COUNT)"
fi

# 4. Verificer version for canary tenants
CANARY_POD=$(kubectl get pods -A -l canary=true --no-headers | head -1 | awk '{print $2}')
CANARY_VERSION=$(kubectl get pod -n $CANARY_POD -o jsonpath='{.spec.containers[0].image}' | grep -oP '\d+\.\d+\.\d+')
if [ "$CANARY_VERSION" = "23.0.2" ]; then
  echo "PASS: Canary tenant har version 23.0.2"
else
  echo "FAIL: Canary tenant har forkert version (forventet 23.0.2, got $CANARY_VERSION)"
fi

# 5. Verificer healthz for canary tenants
for pod in $(kubectl get pods -A -l canary=true --no-headers | awk '{print $2}'); do
  ns=$(echo $pod | cut -d'/' -f1)
  pod_name=$(echo $pod | cut -d'/' -f2)
  contract=${ns#tenant-}
  curl -fsS -o /dev/null -m 5 "https://${contract}.${TENANT_DOMAIN}/healthz"
  if [ $? -eq 0 ]; then
    echo "PASS: Healthz OK for $contract"
  else
    echo "FAIL: Healthz failed for $contract"
  fi
done
```

**Expected Result:**
- 1 canary tenant valgt (5% af 20)
- Canary tenant har version 23.0.2
- Healthz checks passeret for canary tenant

**Cleanup:**
```bash
# Vent paa canary window (30 minutter) eller annuller test
# For test: koer full rollout manuelt
export CANARY_PERCENTAGE=100
./Scripts/canary-rollout.sh
```

---

### Test 2-02: Canary-rollout (Premium Plan)

**Formaal:** Verificere at canary-rollout fungerer for premium plan tenants.

**Steps:**
1. Resetter rotationsindeks for premium plan
2. Koer canary-rollout med ny version
3. Verificer at korrekt antal canary tenants er valgt
4. Verificer at canary tenants har ny version
5. Verificer healthz checks for canary tenants

**Commands:**
```bash
# 1. Reset rotationsindeks
echo 0 > /var/lib/saasplatform/canary-index-premium-k8s-prod.txt

# 2. Koer canary-rollout
export SELLYOURSAAS_VERSION="23.0.2"
./Scripts/canary-rollout.sh

# 3. Verificer antal canary tenants (10% af 10 = 1 tenant)
CANARY_COUNT=$(kubectl get pods -A -l canary=true --no-headers | wc -l)
if [ "$CANARY_COUNT" -eq 1 ]; then
  echo "PASS: Korrekt antal canary tenants (1)"
else
  echo "FAIL: Forkert antal canary tenants (forventet 1, got $CANARY_COUNT)"
fi

# 4. Verificer version for canary tenants
CANARY_POD=$(kubectl get pods -A -l canary=true --no-headers | head -1 | awk '{print $2}')
CANARY_VERSION=$(kubectl get pod -n $CANARY_POD -o jsonpath='{.spec.containers[0].image}' | grep -oP '\d+\.\d+\.\d+')
if [ "$CANARY_VERSION" = "23.0.2" ]; then
  echo "PASS: Canary tenant har version 23.0.2"
else
  echo "FAIL: Canary tenant har forkert version (forventet 23.0.2, got $CANARY_VERSION)"
fi

# 5. Verificer healthz for canary tenants
for pod in $(kubectl get pods -A -l canary=true --no-headers | awk '{print $2}'); do
  ns=$(echo $pod | cut -d'/' -f1)
  pod_name=$(echo $pod | cut -d'/' -f2)
  contract=${ns#tenant-}
  curl -fsS -o /dev/null -m 5 "https://${contract}.${TENANT_DOMAIN}/healthz"
  if [ $? -eq 0 ]; then
    echo "PASS: Healthz OK for $contract"
  else
    echo "FAIL: Healthz failed for $contract"
  fi
done
```

**Expected Result:**
- 1 canary tenant valgt (10% af 10)
- Canary tenant har version 23.0.2
- Healthz checks passeret for canary tenant

**Cleanup:**
```bash
# Vent paa canary window (30 minutter) eller annuller test
export CANARY_PERCENTAGE=100
./Scripts/canary-rollout.sh
```

---

### Test 2-03: Canary Rotation

**Formaal:** Verificere at rotationsindeks fungerer korrekt.

**Steps:**
1. Resetter rotationsindeks
2. Koer canary-rollout 3 gange
3. Verificer at forskellige tenants vaelges hver gang

**Commands:**
```bash
# 1. Reset rotationsindeks
echo 0 > /var/lib/saasplatform/canary-index-standard-k8s-prod.txt

# 2. Koer canary-rollout 3 gange
for i in {1..3}; do
  echo "=== Iteration $i ==="
  ./Scripts/canary-rollout.sh
  sleep 5
  
  # 3. Verificer canary tenant
  CANARY_POD=$(kubectl get pods -A -l canary=true --no-headers | head -1 | awk '{print $2}')
  echo "Canary tenant: $CANARY_POD"
  
  # Gem canary tenant for iteration
  echo "$CANARY_POD" >> /tmp/canary-tenants.txt
  
  # Reset for naeste iteration
  kubectl delete pods -A -l canary=true --wait
  sleep 5
done

# 4. Verificer at forskellige tenants vaelges
UNIQUE_TENANTS=$(sort /tmp/canary-tenants.txt | uniq | wc -l)
if [ "$UNIQUE_TENANTS" -eq 3 ]; then
  echo "PASS: 3 forskellige tenants valgt"
else
  echo "FAIL: Mindst 2 tenants var ens (unique: $UNIQUE_TENANTS)"
fi

# 5. Verificer rotationsindeks
INDEX=$(cat /var/lib/saasplatform/canary-index-standard-k8s-prod.txt)
if [ "$INDEX" -eq 3 ]; then
  echo "PASS: Rotationsindeks inkrementeret til 3"
else
  echo "FAIL: Rotationsindeks er $INDEX (forventet 3)"
fi
```

**Expected Result:**
- 3 forskellige tenants valgt over 3 iterationer
- Rotationsindeks inkrementeret til 3

**Cleanup:**
```bash
rm /tmp/canary-tenants.txt
```

---

### Test 2-04: Canary Fejlhaandtering

**Formaal:** Verificere at canary-rollout haandterer fejl korrekt (rollback).

**Steps:**
1. Deploy en tenant med version 23.0.1
2. Koer canary-rollout til version 23.0.2
3. Simuler fejl (slet DB-pod for canary tenant)
4. Verificer at rollback sker

**Commands:**
```bash
# 1. Reset rotationsindeks
echo 0 > /var/lib/saasplatform/canary-index-standard-k8s-prod.txt

# 2. Deploy en enkelt test tenant
export SELLYOURSAAS_INSTANCE_NAME="canary-fail-test-01"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://canary-fail-test-01.${TENANT_DOMAIN}"
export SELLYOURSAAS_VERSION="23.0.1"
export SELLYOURSAAS_PLAN="standard"
./Scripts/deploy.sh "canary-fail-test-01"
sleep 15

# 3. Koer canary-rollout
export SELLYOURSAAS_VERSION="23.0.2"
export CANARY_PERCENTAGE=100  # Force canary for this tenant
./Scripts/canary-rollout.sh
sleep 10

# 4. Simuler fejl (slet DB-pod)
CANARY_NS=$(kubectl get pods -A -l canary=true --no-headers | head -1 | awk '{print $1}')
kubectl delete pod -n $CANARY_NS -l app.kubernetes.io/component=db --force --grace-period=0
sleep 5

# 5. Verificer at healthz fejler
CANARY_CONTRACT=${CANARY_NS#tenant-}
curl -fsS -o /dev/null -m 5 "https://${CANARY_CONTRACT}.${TENANT_DOMAIN}/healthz"
if [ $? -ne 0 ]; then
  echo "PASS: Healthz fejler som forventet"
else
  echo "FAIL: Healthz burde fejle"
fi

# 6. Vent paa rollback (eller trigger manuelt)
# Canary-rollout script burde detektere fejl og rollback
sleep 60

# 7. Verificer rollback
VERSION=$(kubectl get deployment -n $CANARY_NS dolibarr -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -oP '\d+\.\d+\.\d+')
if [ "$VERSION" = "23.0.1" ]; then
  echo "PASS: Rollback til version 23.0.1"
else
  echo "FAIL: Rollback mislykkedes (version: $VERSION)"
fi

# 8. Verificer healthz efter rollback
curl -fsS -o /dev/null -m 5 "https://${CANARY_CONTRACT}.${TENANT_DOMAIN}/healthz"
if [ $? -eq 0 ]; then
  echo "PASS: Healthz OK efter rollback"
else
  echo "FAIL: Healthz fejler efter rollback"
fi
```

**Expected Result:**
- Healthz fejler efter DB-pod er slettet
- Rollback til version 23.0.1
- Healthz OK efter rollback

**Cleanup:**
```bash
./Scripts/undeploy.sh "canary-fail-test-01"
```

---

### Test 2-05: Velero Backup (Alle Tenants)

**Formaal:** Verificere at Velero kan tage backup af alle tenants.

**Steps:**
1. Tag backup af alle tenants
2. Verificer backup i Velero
3. Verificer backup i S3

**Commands:**
```bash
# 1. Tag backup
velero backup create test-all-tenants-backup \
  --include-namespaces tenant-* \
  --wait

# 2. Verificer backup i Velero
BACKUP_STATUS=$(velero backup get test-all-tenants-backup -o jsonpath='{.status.phase}')
if [ "$BACKUP_STATUS" = "Completed" ]; then
  echo "PASS: Backup completed"
else
  echo "FAIL: Backup status: $BACKUP_STATUS"
fi

# 3. Verificer backup i S3
AWS_ACCESS_KEY_ID=$(cat /etc/saasplatform/velero-credentials | grep aws_access_key_id | cut -d= -f2 | tr -d ' ')
AWS_SECRET_ACCESS_KEY=$(cat /etc/saasplatform/velero-credentials | grep aws_secret_access_key | cut -d= -f2 | tr -d ' ')
BACKUP_COUNT=$(aws s3 --endpoint-url=$S3_ENDPOINT ls s3://$S3_BUCKET/backup/test-all-tenants-backup/ --recursive | wc -l)
if [ "$BACKUP_COUNT" -gt 0 ]; then
  echo "PASS: Backup fundet i S3"
else
  echo "FAIL: Backup ikke fundet i S3"
fi
```

**Expected Result:**
- Backup status: Completed
- Backup fundet i S3

**Cleanup:**
```bash
# Slet backup
velero backup delete test-all-tenants-backup --confirm
```

---

### Test 2-06: Velero Restore (Tenant)

**Formaal:** Verificere at Velero kan restore en tenant.

**Steps:**
1. Tag backup af en test tenant
2. Slet tenant
3. Restore tenant
4. Verificer tenant fungerer

**Commands:**
```bash
# 1. Tag backup af test tenant
velero backup create test-restore-backup \
  --include-namespaces tenant-canary-test-standard-1 \
  --wait

# 2. Slet tenant
./Scripts/undeploy.sh "canary-test-standard-1"
sleep 10

# 3. Verificer tenant er slettet
TENANT_NS="tenant-canary-test-standard-1"
if ! kubectl get ns $TENANT_NS &>/dev/null; then
  echo "PASS: Tenant slettet"
else
  echo "FAIL: Tenant findes stadig"
fi

# 4. Restore tenant
velero restore create --from-backup test-restore-backup \
  --include-namespaces $TENANT_NS \
  --wait \
  --timeout 10m

# 5. Verificer tenant fungerer
if kubectl get ns $TENANT_NS &>/dev/null; then
  echo "PASS: Tenant restaureret"
else
  echo "FAIL: Tenant ikke restaureret"
fi

# 6. Verificer pods koerer
POD_COUNT=$(kubectl get pods -n $TENANT_NS --no-headers | grep -c Running)
if [ "$POD_COUNT" -ge 2 ]; then
  echo "PASS: Pods koerer"
else
  echo "FAIL: Pods koerer ikke (count: $POD_COUNT)"
fi

# 7. Verificer healthz
curl -fsS -o /dev/null -m 5 "https://canary-test-standard-1.${TENANT_DOMAIN}/healthz"
if [ $? -eq 0 ]; then
  echo "PASS: Healthz OK"
else
  echo "FAIL: Healthz fejler"
fi
```

**Expected Result:**
- Tenant slettet
- Tenant restaureret
- Pods koerer
- Healthz OK

**Cleanup:**
```bash
# Slet backup
velero backup delete test-restore-backup --confirm
velero restore delete test-restore-backup --confirm
```

---

### Test 2-07: Natlig DB-dump

**Formaal:** Verificere at natlig DB-dump fungerer.

**Steps:**
1. Trigger DB-dump CronJob manuelt
2. Verificer DB-dump i S3
3. Verificer DB-dump kan downloades

**Commands:**
```bash
# 1. Trigger DB-dump manuelt
kubectl create job --from=cronjob/backup -n tenant-canary-test-standard-1

# 2. Vent paa job færdig
sleep 30
JOB_STATUS=$(kubectl get job -n tenant-canary-test-standard-1 -l app.kubernetes.io/managed-by=Helm --no-headers | awk '{print $3}')
if [ "$JOB_STATUS" = "1/1" ]; then
  echo "PASS: Job completed"
else
  echo "FAIL: Job status: $JOB_STATUS"
fi

# 3. Verificer DB-dump i S3
DUMP_FILE=$(aws s3 --endpoint-url=$S3_ENDPOINT ls s3://$S3_BUCKET/daily/tenant-canary-test-standard-1/ | grep -i backup | tail -1 | awk '{print $4}')
if [ -n "$DUMP_FILE" ]; then
  echo "PASS: DB-dump fundet i S3"
else
  echo "FAIL: DB-dump ikke fundet i S3"
fi

# 4. Download og verificer DB-dump
aws s3 --endpoint-url=$S3_ENDPOINT cp s3://$S3_BUCKET/daily/tenant-canary-test-standard-1/$DUMP_FILE /tmp/
if [ -f /tmp/$DUMP_FILE ]; then
  echo "PASS: DB-dump downloadet"
  # Tjek at filen er en valid gzip
  if gzip -t /tmp/$DUMP_FILE; then
    echo "PASS: DB-dump er valid gzip"
  else
    echo "FAIL: DB-dump er ikke valid gzip"
  fi
else
  echo "FAIL: DB-dump kunne ikke downloades"
fi
```

**Expected Result:**
- Job completed
- DB-dump fundet i S3
- DB-dump downloadet og valid

**Cleanup:**
```bash
rm /tmp/$DUMP_FILE
```

---

### Test 2-08: Prometheus Metrikker

**Formaal:** Verificere at Prometheus indsamler metrikker korrekt.

**Steps:**
1. Port-forward til Prometheus
2. Tjek targets
3. Tjek metrikker

**Commands:**
```bash
# 1. Port-forward til Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
PROM_PID=$!
sleep 2

# 2. Tjek targets
TARGETS_STATUS=$(curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[].health')
if echo "$TARGETS_STATUS" | grep -q "up"; then
  echo "PASS: Targets viser healthy"
else
  echo "FAIL: Targets ikke healthy"
fi

# 3. Tjek metrikker for tenants
TENANT_METRICS=$(curl -s "http://localhost:9090/api/v1/query?query=up{namespace=~\"tenant-.*\"}" | jq -r '.data.result[].value[1]')
if [ "$TENANT_METRICS" = "1" ]; then
  echo "PASS: Tenant metrikker indsamlet"
else
  echo "FAIL: Tenant metrikker ikke indsamlet"
fi

# 4. Cleanup
kill $PROM_PID
```

**Expected Result:**
- Targets viser healthy
- Tenant metrikker indsamlet

---

### Test 2-09: Grafana Dashboards

**Formaal:** Verificere at Grafana fungerer og viser data.

**Steps:**
1. Port-forward til Grafana
2. Login
3. Tjek dashboards

**Commands:**
```bash
# 1. Port-forward til Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80 &
GRAFANA_PID=$!
sleep 2

# 2. Tjek login (bruger curl til at teste)
LOGIN_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  http://localhost:3000/login \
  -H "Content-Type: application/json" \
  -d '{"user":"admin","password":"<password>"}')
if [ "$LOGIN_RESPONSE" = "200" ]; then
  echo "PASS: Login fungerer"
else
  echo "FAIL: Login fejler (HTTP $LOGIN_RESPONSE)"
fi

# 3. Tjek dashboards (manuelt)
echo "Manual check: Gaa til http://localhost:3000 og verificer dashboards"

# 4. Cleanup
kill $GRAFANA_PID
```

**Expected Result:**
- Login fungerer
- Dashboards viser data (manuelt check)

---

### Test 2-10: Loki Logging

**Formaal:** Verificere at Loki indsamler logs korrekt.

**Steps:**
1. Port-forward til Loki
2. Query logs
3. Verificer logs

**Commands:**
```bash
# 1. Port-forward til Loki
kubectl port-forward -n monitoring svc/loki 3100:3100 &
LOKI_PID=$!
sleep 2

# 2. Query logs
LOGS=$(curl -s -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={namespace=~"tenant-.*"}' | jq -r '.data.result[].values[0][1]')
if [ -n "$LOGS" ]; then
  echo "PASS: Logs fundet"
else
  echo "FAIL: Logs ikke fundet"
fi

# 3. Query specifik tenant logs
TENANT_LOGS=$(curl -s -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={namespace="tenant-canary-test-standard-1"}' | jq -r '.data.result[].values[0][1]')
if [ -n "$TENANT_LOGS" ]; then
  echo "PASS: Tenant logs fundet"
else
  echo "FAIL: Tenant logs ikke fundet"
fi

# 4. Cleanup
kill $LOKI_PID
```

**Expected Result:**
- Logs fundet
- Tenant logs fundet

---

### Test 2-11: Alerts (Tenant Nedetid)

**Formaal:** Verificere at alerts triggeres ved tenant nedetid.

**Steps:**
1. Simuler tenant nedetid (slet pod)
2. Vent paa alert
3. Verificer alert

**Commands:**
```bash
# 1. Port-forward til Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
PROM_PID=$!
sleep 2

# 2. Simuler tenant nedetid
kubectl delete pod -n tenant-canary-test-standard-1 -l app=dolibarr --force --grace-period=0
sleep 5

# 3. Vent paa alert (5 minutter)
sleep 300

# 4. Tjek aktive alerts
ALERTS=$(curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "TenantDown") | .labels.namespace')
if echo "$ALERTS" | grep -q "tenant-canary-test-standard-1"; then
  echo "PASS: TenantDown alert triggeret"
else
  echo "FAIL: TenantDown alert ikke triggeret"
fi

# 5. Cleanup
kill $PROM_PID

# 6. Genstart pod
kubectl rollout restart deployment/dolibarr -n tenant-canary-test-standard-1
```

**Expected Result:**
- TenantDown alert triggeret

**Cleanup:**
```bash
# Vent paa alert resolved
sleep 300
```

---

### Test 2-12: Alerts (High CPU)

**Formaal:** Verificere at alerts triggeres ved high CPU usage.

**Steps:**
1. Simuler high CPU (stress test)
2. Vent paa alert
3. Verificer alert

**Commands:**
```bash
# 1. Port-forward til Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
PROM_PID=$!
sleep 2

# 2. Simuler high CPU
kubectl run stress-test --image=stressng --restart=Never -n tenant-canary-test-standard-1 -- \
  --cpu 2 --cpu-load 100 --timeout 300s
sleep 5

# 3. Vent paa alert (5 minutter)
sleep 300

# 4. Tjek aktive alerts
ALERTS=$(curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "HighCPUUsage") | .labels.namespace')
if echo "$ALERTS" | grep -q "tenant-canary-test-standard-1"; then
  echo "PASS: HighCPUUsage alert triggeret"
else
  echo "FAIL: HighCPUUsage alert ikke triggeret"
fi

# 5. Cleanup
kill $PROM_PID
kubectl delete pod stress-test -n tenant-canary-test-standard-1 --force
```

**Expected Result:**
- HighCPUUsage alert triggeret

---

### Test 2-13: Alerts (Certificate Expiration)

**Formaal:** Verificere at alerts triggeres ved certificate expiration.

**Steps:**
1. Opret en test certificate med kort expiration
2. Vent paa alert
3. Verificer alert

**Commands:**
```bash
# 1. Port-forward til Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
PROM_PID=$!
sleep 2

# 2. Opret test certificate (expirer om 1 dag)
cat > /tmp/test-certificate.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-expiring-cert
  namespace: tenant-canary-test-standard-1
spec:
  secretName: test-expiring-cert-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "test-expiring.${TENANT_DOMAIN}"
  duration: 24h
  renewBefore: 1h
EOF
kubectl apply -f /tmp/test-certificate.yaml
sleep 10

# 3. Vent paa certificate udstedelse
kubectl wait --for=condition=Ready certificate/test-expiring-cert -n tenant-canary-test-standard-1 --timeout=300s

# 4. Vent paa alert (cert expirer om ~23 timer)
sleep 1800

# 5. Tjek aktive alerts
ALERTS=$(curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname == "CertificateExpiring") | .labels.namespace')
if echo "$ALERTS" | grep -q "tenant-canary-test-standard-1"; then
  echo "PASS: CertificateExpiring alert triggeret"
else
  echo "FAIL: CertificateExpiring alert ikke triggeret"
fi

# 6. Cleanup
kill $PROM_PID
kubectl delete -f /tmp/test-certificate.yaml
rm /tmp/test-certificate.yaml
```

**Expected Result:**
- CertificateExpiring alert triggeret

---

### Test 2-14: Produktionsmiljo (k3s)

**Formaal:** Verificere at produktionsmiljoet for k3s fungerer.

**Steps:**
1. Verificer alle tenants deployet
2. Verificer healthz for alle tenants
3. Verificer certifikater

**Commands:**
```bash
# 1. Verificer alle tenants deployet
TENANT_COUNT=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-' | wc -l)
if [ "$TENANT_COUNT" -ge 30 ]; then  # 20 standard + 10 premium
  echo "PASS: Alle tenants deployet (count: $TENANT_COUNT)"
else
  echo "FAIL: Ikke alle tenants deployet (count: $TENANT_COUNT)"
fi

# 2. Verificer healthz for alle tenants
FAILED_HEALTHZ=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  contract=${ns#tenant-}
  if ! curl -fsS -o /dev/null -m 5 "https://${contract}.${TENANT_DOMAIN}/healthz" &>/dev/null; then
    echo "FAIL: Healthz fejler for $contract"
    FAILED_HEALTHZ=$((FAILED_HEALTHZ + 1))
  fi
done
if [ "$FAILED_HEALTHZ" -eq 0 ]; then
  echo "PASS: Healthz OK for alle tenants"
else
  echo "FAIL: Healthz fejler for $FAILED_HEALTHZ tenants"
fi

# 3. Verificer certifikater
FAILED_CERTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  CERT_STATUS=$(kubectl get certificate -n $ns -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$CERT_STATUS" != "True" ]; then
    echo "FAIL: Certifikat ikke ready for $ns"
    FAILED_CERTS=$((FAILED_CERTS + 1))
  fi
done
if [ "$FAILED_CERTS" -eq 0 ]; then
  echo "PASS: Certifikater ready for alle tenants"
else
  echo "FAIL: Certifikater ikke ready for $FAILED_CERTS tenants"
fi
```

**Expected Result:**
- Alle tenants deployet
- Healthz OK for alle tenants
- Certifikater ready for alle tenants

---

### Test 2-15: Produktionsmiljo (Native)

**Formaal:** Verificere at produktionsmiljoet for native deployment fungerer.

**Steps:**
1. Verificer native tenants deployet
2. Verificer healthz for native tenants

**Commands:**
```bash
# 1. Verificer native tenants deployet
# Antager at native deployment er konfigureret i SellYourSaaS
NATIVE_COUNT=$(ls /var/www/html/ | grep -c '^pim-')
if [ "$NATIVE_COUNT" -gt 0 ]; then
  echo "PASS: Native tenants deployet (count: $NATIVE_COUNT)"
else
  echo "FAIL: Ingen native tenants deployet"
fi

# 2. Verificer healthz for native tenants
FAILED_HEALTHZ=0
for tenant in $(ls /var/www/html/ | grep '^pim-'); do
  if ! curl -fsS -o /dev/null -m 5 "https://${tenant}.native.saasplatform.dk/healthz" &>/dev/null; then
    echo "FAIL: Healthz fejler for $tenant"
    FAILED_HEALTHZ=$((FAILED_HEALTHZ + 1))
  fi
done
if [ "$FAILED_HEALTHZ" -eq 0 ]; then
  echo "PASS: Healthz OK for alle native tenants"
else
  echo "FAIL: Healthz fejler for $FAILED_HEALTHZ native tenants"
fi
```

**Expected Result:**
- Native tenants deployet
- Healthz OK for alle native tenants

---

## Test Cleanup

```bash
# Slet alle test tenants
for i in $(seq 1 20); do
  ./Scripts/undeploy.sh "canary-test-standard-${i}"
done
for i in $(seq 1 10); do
  ./Scripts/undeploy.sh "canary-test-premium-${i}"
done
./Scripts/undeploy.sh "canary-fail-test-01"

# Reset rotationsindeks
rm -f /var/lib/saasplatform/canary-index-*.txt
for strata in standard premium; do
  for server in k8s-prod native-prod; do
    echo 0 > /var/lib/saasplatform/canary-index-${strata}-${server}.txt
  done
done

# Slet Velero backups
velero backup delete test-all-tenants-backup --confirm 2>/dev/null
velero backup delete test-restore-backup --confirm 2>/dev/null
velero restore delete test-restore-backup --confirm 2>/dev/null

# Slet test certificate
kubectl delete certificate test-expiring-cert -n tenant-canary-test-standard-1 2>/dev/null

# Slet stress-test pod
kubectl delete pod stress-test -n tenant-canary-test-standard-1 2>/dev/null
```

---

## Exit Kriterier

### Minimum (for at gaa videre til fase 3)

- [ ] **2-01** Canary-rollout (standard) fungerer
- [ ] **2-02** Canary-rollout (premium) fungerer
- [ ] **2-05** Velero backup fungerer
- [ ] **2-06** Velero restore fungerer
- [ ] **2-08** Prometheus metrikker fungerer
- [ ] **2-11** Alerts (tenant nedetid) fungerer
- [ ] **2-13** Alerts (certificate expiration) fungerer
- [ ] **2-14** Produktionsmiljo (k3s) fungerer

### Fuldt (anbefalet)

- [ ] Alle 15 tests bestaaet
- [ ] CI-niveau 2 (integrations-test) groen
- [ ] Dokumentation komplet
- [ ] Runbooks oprettet

---

## Ressourcer

- [Fase 2 README](README.md)
- [Fase 2 Installationstjekliste](Installationstjekliste.md)
- [Produktions-opsaetningsguide](Produktions-opsætningsguide.md)
- [Arkitektur.md](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
- [Canary-rollout Script](../../Scripts/canary-rollout.sh)
- [Velero Dokumentation](https://velero.io/docs/)
- [Prometheus Dokumentation](https://prometheus.io/docs/)
- [Grafana Dokumentation](https://grafana.com/docs/)
- [Loki Dokumentation](https://grafana.com/docs/loki/latest/)
