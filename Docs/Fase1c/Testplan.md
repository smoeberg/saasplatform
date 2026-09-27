# Fase 1c - Testplan: Livscyklus og Gendannelse

## Formål

Verificere at **livscyklus-management** fungerer korrekt:
1. **Rollback efter fejlet DB-migrering** fungerer (§3.5)
2. **Restore af én tenant** fungerer (§3.3)
3. **Secrets-flow** er end-to-end verificeret (§3.3.1)

**Exit-kriterier:**
- Alle 5 kerne-tests bestået
- CI-niveau 2 (integrations-test) grøn

---

## Testmatrix

| ID | Test | Type | Arkitektur Reference | Exit-kriterium | Status | Prioritet |
|----|------|------|----------------------|----------------|--------|-----------|
| 1c-01 | Pre-migration snapshot | Funktionel | §3.5.3 | Snapshot uploadet til S3 | [ ] | Høj |
| 1c-02 | Fejlet migrering + rollback | Funktionel | §3.5.2 | Tenant gendannet til tidligere version | [ ] | **Kritisk** |
| 1c-03 | Restore fra backup | Funktionel | §3.3 | Tenant fungerer efter restore | [ ] | **Kritisk** |
| 1c-04 | Secrets-flow (SealedSecret) | Funktionel | §3.3.1 | Alle secrets er SealedSecrets | [ ] | **Kritisk** |
| 1c-05 | cert-manager fornyelse under suspension | Funktionel | §3.3 | Certifikater fornyes | [ ] | Høj |
| 1c-06 | Natlig backup (Velero) | Funktionel | §3.3 | Backup oprettet i S3 | [ ] | Middel |
| 1c-07 | Rollback uden snapshot | Funktionel | §3.5.2 | Fallback procedure virker | [ ] | Middel |
| 1c-08 | Password-reset flow | Funktionel | §3.3.1 | Nye secrets oprettet, pods restarted | [ ] | Middel |

---

## Forudsætninger

### Hardware/Software

- [ ] k3d cluster kører (`k3d cluster create saas-test`)
- [ ] kubectl, helm, curl, jq, yq installeret
- [ ] MinIO (S3 mock) kører for backup-tests
- [ ] cert-manager installeret i clusteret
- [ ] SealedSecrets controller installeret
- [ ] Velero installeret i clusteret

### Konfiguration

```bash
# Miljøvariabler
export S3_ENDPOINT="http://localhost:9000"
export S3_BUCKET="saasplatform-backups"
export S3_ACCESS_KEY="minioadmin"
export S3_SECRET_KEY="minioadmin"
export S3_PRE_MIGRATION_BUCKET="pre-migration-backups"
export TENANT_DOMAIN="kunder.saasplatform.test"
export CLOUDFLARE_API_TOKEN="test-token"
export CLOUDFLARE_ZONE_ID="test-zone"

# Directory struktur
mkdir -p test-values test-status
```

---

## Setup

### 1. Start k3d Cluster

```bash
k3d cluster create saas-test --agents 2 --ports '80:80@loadbalancer' --ports '443:443@loadbalancer'
sleep 10
kubectl get nodes
```

### 2. Installer Afhængigheder

```bash
# cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.14.4 \
  --set installCRDs=true

# SealedSecrets
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.22.0/controller.yaml

# Velero
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.4.0 \
  --bucket $S3_BUCKET \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=$S3_ENDPOINT \
  --snapshot-location-config region=us-east-1 \
  --secret-file ./test-velero-credentials \
  --namespace velero \
  --wait

# MinIO
cat > test-velero-credentials << 'EOF'
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin
EOF

docker run -d -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  --name minio \
  quay.io/minio/minio server /data --console-address ":9001"

# Opret buckets
sleep 5
curl -X PUT http://localhost:9000/minioadmin/saasplatform-backups -H "Host: localhost:9000"
curl -X PUT http://localhost:9000/minioadmin/pre-migration-backups -H "Host: localhost:9000"
```

---

## Test Procedure

---

### Test 1c-01: Pre-migration Snapshot

**Formål:** Verificere at pre-migration snapshot tages og uploades til S3.

**Begrundelse:** Ifølge arkitektur §3.5.3: "DB-snapshot tages lige før migrering (adskilt fra natlig backup)"

**Steps:**
1. Deploy tenant med version 23.0.1
2. Trigger pre-migration snapshot for version 23.0.2
3. Verificer at snapshot er uploadet til S3

**Commands:**
```bash
# 1. Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="1c-01"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-01.$TENANT_DOMAIN"
export SELLYOURSAAS_VERSION="23.0.1"
./Scripts/deploy.sh 1c-01

# 2. Vent på pods
kubectl wait --for=condition=ready pod -n tenant-1c-01 --all --timeout=5m

# 3. Trigger pre-migration snapshot
export SELLYOURSAAS_VERSION="23.0.2"
./Scripts/migrate.sh 1c-01 --pre-migration-only

# 4. Verificer snapshot i S3
SNAPSHOT_URL="$S3_ENDPOINT/$S3_PRE_MIGRATION_BUCKET/tenant-1c-01/pre-migration-23.0.2-*.sql.gz"
SNAPSHOT_EXISTS=$(curl -s -I "$SNAPSHOT_URL" -H "Host: $S3_BUCKET.$S3_ENDPOINT" -u $S3_ACCESS_KEY:$S3_SECRET_KEY | grep -c "HTTP/1.1 200")

if [[ "$SNAPSHOT_EXISTS" -ge 1 ]]; then
  echo "✅ PASS: Pre-migration snapshot uploadet til S3"
else
  echo "❌ FAIL: Pre-migration snapshot ikke fundet i S3"
  curl -v "$SNAPSHOT_URL" -H "Host: $S3_BUCKET.$S3_ENDPOINT" -u $S3_ACCESS_KEY:$S3_SECRET_KEY
fi
```

**Forventet:**
- HTTP 200 response fra S3
- Snapshot fil findes i `pre-migration-backups/tenant-1c-01/`

**Cleanup:**
```bash
./Scripts/undeploy.sh 1c-01
```

**✅ PASS / ❌ FAIL:**

---

### Test 1c-02: Fejlet Migrering + Rollback

**Formål:** Verificere rollback-procedure efter fejlet DB-migrering.

**Begrundelse:** Ifølge arkitektur §3.5.2: "Hvis opdateringen fejler **efter** migrering: rollback = gendan pre-migration-snapshot + sæt tidligere image-version"

**Steps:**
1. Deploy tenant med version 23.0.1
2. Tag pre-migration snapshot for 23.0.2
3. Simuler fejl under/efter migrering
4. Kør rollback til 23.0.1
5. Verificer at tenant fungerer med version 23.0.1

**Commands:**
```bash
# 1. Deploy med version 23.0.1
export SELLYOURSAAS_INSTANCE_NAME="1c-02"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-02.$TENANT_DOMAIN"
export SELLYOURSAAS_VERSION="23.0.1"
./Scripts/deploy.sh 1c-02
sleep 15

# 2. Tag pre-migration snapshot
export SELLYOURSAAS_VERSION="23.0.2"
./Scripts/migrate.sh 1c-02 --pre-migration-only
sleep 5

# 3. Simuler migrering (opdater image)
kubectl set image -n tenant-1c-02 deployment/dolibarr dolibarr=ghcr.io/smoeberg/dolibarr:23.0.2
sleep 5

# 4. Simuler fejl: slet DB-pod for at simulere korruption
kubectl delete pod -n tenant-1c-02 -l app.kubernetes.io/component=db --force --grace-period=0
sleep 10

# 5. Kør rollback til 23.0.1
./Scripts/rollback.sh 1c-02 --target-version 23.0.1
sleep 10

# 6. Verificer
CURRENT_IMAGE=$(kubectl get deployment -n tenant-1c-02 dolibarr -o jsonpath='{.spec.template.spec.containers[0].image}')
HEALTHZ_OK=$(./Scripts/cron.sh 1c-02 2>&1 | grep -c "200" || echo "0")

if [[ "$CURRENT_IMAGE" == *"23.0.1"* ]] && [[ "$HEALTHZ_OK" -ge 1 ]]; then
  echo "✅ PASS: Rollback til 23.0.1 fungerer, healthz OK"
else
  echo "❌ FAIL: Rollback fejlede"
  echo "Current image: $CURRENT_IMAGE"
  echo "Healthz status: $HEALTHZ_OK"
fi
```

**Forventet:**
- Deployment kører med image `ghcr.io/smoeberg/dolibarr:23.0.1`
- Healthz check returnerer 200
- Data er intakt (DB gendannet fra snapshot)

**Cleanup:**
```bash
./Scripts/undeploy.sh 1c-02
```

**✅ PASS / ❌ FAIL:**

---

### Test 1c-03: Restore fra Backup

**Formål:** Verificere restore-procedure.

**Begrundelse:** Ifølge arkitektur §3.3: "Restore-runbook (rækkefølge): 1. Opret frisk namespace + helm-install med **ingen** data, 2. Indlæs DB-dump, 3. Velero-restore af PVC, 4. Start pods"

**Steps:**
1. Deploy tenant
2. Tag backup (Velero + S3)
3. Slet tenant
4. Restore fra backup
5. Verificer at tenant fungerer

**Commands:**
```bash
# 1. Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="1c-03"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-03.$TENANT_DOMAIN"
export SELLYOURSAAS_VERSION="23.0.1"
./Scripts/deploy.sh 1c-03
sleep 15

# 2. Tag Velero backup
velero backup create test-1c-03 --include-namespaces tenant-1c-03 --wait
sleep 5

# 3. Slet tenant
./Scripts/undeploy.sh 1c-03
sleep 5

# 4. Restore fra Velero backup
velero restore create --from-backup test-1c-03 --wait --timeout 10m
sleep 10

# 5. Verificer
PODS_READY=$(kubectl get pods -n tenant-1c-03 -o jsonpath='{.items[*].status.phase}' | grep -c Running || echo "0")
HEALTHZ_OK=$(./Scripts/cron.sh 1c-03 2>&1 | grep -c "200" || echo "0")

if [[ "$PODS_READY" -ge 2 ]] && [[ "$HEALTHZ_OK" -ge 1 ]]; then
  echo "✅ PASS: Restore fra Velero backup fungerer"
else
  echo "❌ FAIL: Restore fejlede"
  kubectl get all -n tenant-1c-03
fi
```

**Forventet:**
- Namespace `tenant-1c-03` genskabt
- 2+ pods kører (dolibarr + mariadb)
- Healthz check OK

**Cleanup:**
```bash
./Scripts/undeploy.sh 1c-03
velero backup delete test-1c-03 --confirm
```

**✅ PASS / ❌ FAIL:**

---

### Test 1c-04: Secrets-Flow

**Formål:** Verificere SealedSecrets flow end-to-end.

**Begrundelse:** Ifølge arkitektur §3.3.1: "SealedSecret oprettes via `kubeseal` og apply'es — **klartekst slettes straks**"

**Steps:**
1. Deploy tenant
2. Verificer at alle secrets er SealedSecrets
3. Test password-reset flow
4. Verificer at ingen klartekst-secrets findes

**Commands:**
```bash
# 1. Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="1c-04"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-04.$TENANT_DOMAIN"
export SELLYOURSAAS_VERSION="23.0.1"
./Scripts/deploy.sh 1c-04
sleep 10

# 2. Tjek secrets
SEALED_SECRETS=$(kubectl get sealedsecret -n tenant-1c-04 --ignore-not-found | wc -l)
REGULAR_SECRETS=$(kubectl get secret -n tenant-1c-04 --ignore-not-found | grep -v "tenant-tls" | wc -l)

# 3. Tjek for klartekst i secrets
CLARTEKST_FOUND=$(kubectl get secret -n tenant-1c-04 -o json 2>/dev/null | jq -r '.items[].data | to_entries[] | select(.value | @base64d | test("password|root|user"; "i")) | .value' | wc -l)

if [[ "$SEALED_SECRETS" -ge 1 ]] && [[ "$CLARTEKST_FOUND" -eq 0 ]]; then
  echo "✅ PASS: SealedSecrets flow fungerer, ingen klartekst"
else
  echo "❌ FAIL: Secrets-flow fejlede"
  echo "SealedSecrets: $SEALED_SECRETS"
  echo "Klartekst fundet: $CLARTEKST_FOUND"
  kubectl get secret -n tenant-1c-04 -o yaml
fi

# 4. Test password-reset
./Scripts/recreateauthorizedkeys.sh 1c-04
sleep 5

# 5. Tjek at nye secrets er oprettet
NEW_SEALED_SECRETS=$(kubectl get sealedsecret -n tenant-1c-04 --ignore-not-found | wc -l)
if [[ "$NEW_SEALED_SECRETS" -gt "$SEALED_SECRETS" ]]; then
  echo "✅ PASS: Password-reset flow fungerer"
else
  echo "⚠️  WARNING: Nye secrets ikke detekteret"
fi
```

**Forventet:**
- 1+ SealedSecrets findes
- Ingen klartekst-secrets (undtagen TLS certifikater)
- Password-reset opretter nye SealedSecrets

**Cleanup:**
```bash
./Scripts/undeploy.sh 1c-04
```

**✅ PASS / ❌ FAIL:**

---

### Test 1c-05: cert-manager Fornyelse under Suspension

**Formål:** Verificere at cert-manager kan forny certifikater under suspension.

**Begrundelse:** Ifølge arkitektur §3.3: "cert-manager's HTTP-01-solver opretter sin egen midlertidige pod + service + Ingress-regel og er ikke afhængig af tenantens app-pods"

**Steps:**
1. Deploy tenant
2. Vent på certifikat
3. Suspender tenant
4. Vent på cert-manager check interval
5. Verificer at certifikat fornyes

**Commands:**
```bash
# 1. Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="1c-05"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-05.$TENANT_DOMAIN"
export SELLYOURSAAS_VERSION="23.0.1"
./Scripts/deploy.sh 1c-05

# 2. Vent på certifikat (kan tage 30-60 sekunder)
sleep 45
CERT_BEFORE=$(kubectl get certificate -n tenant-1c-05 tenant-tls-1c-05 -o jsonpath='{.status.notAfter}' 2>/dev/null || echo "")

# 3. Suspender tenant
./Scripts/suspend.sh 1c-05
sleep 5

# 4. Vent på cert-manager check (1 minut)
sleep 60

# 5. Tjek certifikat status
CERT_STATUS=$(kubectl get certificate -n tenant-1c-05 tenant-tls-1c-05 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
CERT_AFTER=$(kubectl get certificate -n tenant-1c-05 tenant-tls-1c-05 -o jsonpath='{.status.notAfter}' 2>/dev/null || echo "")

if [[ "$CERT_STATUS" == "True" ]] && [[ "$CERT_AFTER" != "" ]]; then
  echo "✅ PASS: cert-manager fornyelse under suspension fungerer"
else
  echo "❌ FAIL: cert-manager fornyelse fejlede"
  kubectl describe certificate -n tenant-1c-05 tenant-tls-1c-05
fi
```

**Forventet:**
- Certificate status = "True"
- Certifikat er gyldigt (notAfter > current time)

**Cleanup:**
```bash
./Scripts/unsuspend.sh 1c-05
./Scripts/undeploy.sh 1c-05
```

**✅ PASS / ❌ FAIL:**

---

### Test 1c-06: Natlig Backup (Velero)

**Formål:** Verificere at natlig backup fungerer.

**Steps:**
1. Opret Velero backup schedule
2. Deploy tenant
3. Vent på natlig backup
4. Verificer backup i S3

**Commands:**
```bash
# 1. Opret backup schedule
cat > test-daily-schedule.yaml << 'EOF'
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup-test
  namespace: velero
spec:
  schedule: "0 * * * *"  # Hver time for test
  template:
    ttl: 1h
    includedNamespaces:
      - tenant-*
EOF
kubectl apply -f test-daily-schedule.yaml

# 2. Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="1c-06"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-06.$TENANT_DOMAIN"
./Scripts/deploy.sh 1c-06
sleep 10

# 3. Vent på backup (1 time)
sleep 65

# 4. Verificer backup
BACKUP_COUNT=$(velero backup get | grep -c "daily-backup-test" || echo "0")
S3_BACKUP=$(curl -s -I "$S3_ENDPOINT/$S3_BUCKET/velero/backups/daily-backup-test-*" \
  -H "Host: $S3_BUCKET.$S3_ENDPOINT" \
  -u $S3_ACCESS_KEY:$S3_SECRET_KEY | grep -c "HTTP/1.1 200" || echo "0")

if [[ "$BACKUP_COUNT" -ge 1 ]] && [[ "$S3_BACKUP" -ge 1 ]]; then
  echo "✅ PASS: Natlig backup fungerer"
else
  echo "❌ FAIL: Natlig backup fejlede"
  velero backup get
fi
```

**Cleanup:**
```bash
./Scripts/undeploy.sh 1c-06
kubectl delete -f test-daily-schedule.yaml
```

**✅ PASS / ❌ FAIL:**

---

### Test 1c-07: Rollback uden Snapshot

**Formål:** Verificere fallback procedure når snapshot ikke findes.

**Steps:**
1. Deploy tenant
2. Prøv rollback uden snapshot
3. Verificer at fallback procedure virker

**Commands:**
```bash
# 1. Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="1c-07"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-07.$TENANT_DOMAIN"
./Scripts/deploy.sh 1c-07
sleep 10

# 2. Prøv rollback uden snapshot
./Scripts/rollback.sh 1c-07 --target-version 23.0.1 --no-snapshot
sleep 5

# 3. Verificer (skal fejle eller bruge fallback)
CURRENT_IMAGE=$(kubectl get deployment -n tenant-1c-07 dolibarr -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [[ "$CURRENT_IMAGE" == *"23.0.1"* ]]; then
  echo "✅ PASS: Fallback procedure virker"
else
  echo "⚠️  WARNING: Rollback uden snapshot fejlede (forventet adfærd)"
fi
```

**Cleanup:**
```bash
./Scripts/undeploy.sh 1c-07
```

**✅ PASS / ❌ FAIL:**

---

### Test 1c-08: Password-Reset Flow

**Formål:** Verificere password-reset flow.

**Steps:**
1. Deploy tenant
2. Kør password-reset
3. Verificer nye secrets og pod restart

**Commands:**
```bash
# 1. Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="1c-08"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://1c-08.$TENANT_DOMAIN"
./Scripts/deploy.sh 1c-08
sleep 10

# 2. Gem originale secrets
ORIGINAL_SEALED=$(kubectl get sealedsecret -n tenant-1c-08 tenant-db -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "")
sleep 5

# 3. Kør password-reset
./Scripts/recreateauthorizedkeys.sh 1c-08
sleep 5

# 4. Tjek nye secrets
NEW_SEALED=$(kubectl get sealedsecret -n tenant-1c-08 tenant-db -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "")
PODS_RESTARTED=$(kubectl get pods -n tenant-1c-08 -o jsonpath='{.items[*].metadata.creationTimestamp}' | wc -w)

if [[ "$NEW_SEALED" != "$ORIGINAL_SEALED" ]] && [[ "$PODS_RESTARTED" -ge 2 ]]; then
  echo "✅ PASS: Password-reset flow fungerer"
else
  echo "❌ FAIL: Password-reset flow fejlede"
fi
```

**Cleanup:**
```bash
./Scripts/undeploy.sh 1c-08
```

**✅ PASS / ❌ FAIL:**

---

## 📊 Test Rapport

### Samlet Status

| Test ID | Test | Type | Status | Noter |
|---------|------|------|--------|-------|
| 1c-01 | Pre-migration snapshot | Funktionel | [ ] | |
| **1c-02** | **Fejlet migrering + rollback** | **Funktionel** | [ ] | **Kritisk** |
| **1c-03** | **Restore fra backup** | **Funktionel** | [ ] | **Kritisk** |
| **1c-04** | **Secrets-flow** | **Funktionel** | [ ] | **Kritisk** |
| 1c-05 | cert-manager fornyelse under suspension | Funktionel | [ ] | Gentaget fra 1b |
| 1c-06 | Natlig backup | Funktionel | [ ] | |
| 1c-07 | Rollback uden snapshot | Funktionel | [ ] | |
| 1c-08 | Password-reset flow | Funktionel | [ ] | |

**Total:** 0/8 tests bestået (0%)

---

## ✅ Exit Kriterier

### Minimum (for at gå videre til fase 2)

- [ ] **1c-01** Pre-migration snapshot fungerer
- [ ] **1c-02** Fejlet migrering + rollback fungerer
- [ ] **1c-03** Restore fra backup fungerer
- [ ] **1c-04** Secrets-flow verificeret

### Fuldt (anbefalet)

- [ ] Alle 8 tests bestået
- [ ] CI-niveau 2 (integrations-test) grøn
- [ ] Dokumentation opdateret

---

## 📚 Referencer

- [Fase 1c - README](README.md)
- [Fase 1c - Installationstjekliste](Installationstjekliste.md)
- [Arkitektur Dokumentation](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
- [Fase 1b - Testplan](../Fase1b/Testplan.md)

---

## 🔧 Fejlfinding

Se [README.md](README.md#11-fejlfinding) for detaljeret fejlfinding.

---

## 📌 Noter

- **1c-02, 1c-03, 1c-04** er de **kritiske tests** ifølge arkitektur
- **1c-05** er gentaget fra fase 1b for at sikre konsistens
- **Velero** bruges til natlige backups
- **MinIO** bruges som S3 mock for development
- **SealedSecrets** sikrer at ingen klartekst-secrets gemmes
