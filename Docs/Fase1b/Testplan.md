# Fase 1b - Testplan: K8s Grundintegration

## Formål

Verificere at **Kubernetes deployment-type** fungerer korrekt med SellYourSaaS, herunder:
- Deploy af Dolibarr-tenants
- Suspension (skalering til 0, CronJobs slettet)
- Unsuspension (skalering tilbage, CronJobs genskabt)
- Undeploy (namespace slettet)
- **cert-manager fornyelse under suspension** (kritisk ifølge arkitektur §3.3)

## Testmatrix

| ID | Test | Type | Exit-kriterium | Status | Noter |
|----|------|------|----------------|--------|-------|
| 1b-01 | Normal deploy flow | Funktionel | Tenant deployet, healthz OK | [ ] | |
| 1b-02 | Suspension (workloads=0) | Funktionel | Replicas=0, CronJobs slettet | [ ] | |
| 1b-03 | Unsuspension (workloads=1) | Funktionel | Replicas=1, CronJobs genskabt | [ ] | |
| 1b-04 | Undeploy (namespace slettet) | Funktionel | Namespace og values-fil slettet | [ ] | |
| 1b-05 | **cert-manager fornyelse under suspension** | Funktionel | Certificate status = True | [ ] | **Kritisk test** |
| 1b-06 | Deploy fejler (ugyldige values) | Fejlhåndtering | Fejl håndteret, ingen halvfærdig instans | [ ] | |
| 1b-07 | Suspend fejler (release findes ikke) | Fejlhåndtering | Fejl håndteret, korrekt fejlmeddelelse | [ ] | |
| 1b-08 | Healthz timeout | Fejlhåndtering | Timeout håndteret, deploy fejler | [ ] | |
| 1b-09 | DB-pod ikke fundet | Fejlhåndtering | Backup springes over, fejl logges | [ ] | |
| 1b-10 | DNS automatisering | Funktionel | DNS record oprettet og slettet | [ ] | |

---

## Forudsætninger

- [ ] k3s cluster kører med Traefik, cert-manager, sealed-secrets
- [ ] K8s-runner VM er opsat med alle afhængigheder
- [ ] Helm chart (erp-tenant) er kopieret til runner
- [ ] Scripts er kopieret til runner
- [ ] Cloudflare API token og zone ID er konfigureret
- [ ] MinIO (S3 mock) kører for backup tests (fase 1c)

---

## Test Setup

### 1. Start k3d Cluster (til test)

```bash
# Start k3d cluster (hvis ikke allerede kørende)
k3d cluster create saas-test --agents 2 --ports '80:80@loadbalancer' --ports '443:443@loadbalancer'

# Vent på cluster
sleep 10
kubectl get nodes
```

### 2. Installer Afhængigheder

```bash
# Installer cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.14.4 \
  --set installCRDs=true

# Installer SealedSecrets
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.22.0/controller.yaml

# Vent på pods
sleep 15
kubectl get pods -A
```

### 3. Konfigurer Miljø

```bash
# Eksportér miljøvariabler
export KUBECONFIG="$HOME/.kube/config"
export CHART_DIR="$PWD/Helm/erp-tenant"
export VALUES_DIR="$PWD/test-values"
export STATUS_DIR="$PWD/test-status"
export TENANT_DOMAIN="kunder.saasplatform.test"
export S3_ENDPOINT="http://localhost:9000"
export S3_BUCKET="saasplatform-backups"
export S3_ACCESS_KEY="minioadmin"
export S3_SECRET_KEY="minioadmin"

# Opret mapper
mkdir -p "$VALUES_DIR" "$STATUS_DIR"
```

---

## TestProcedure

### Test 1b-01: Normal Deploy Flow

**Formål:** Verificere at en tenant kan deployes korrekt.

**Steps:**
1. Kør deploy.sh for en test-tenant
2. Vent på at pods er ready
3. Verificer at alle ressourcer er oprettet

**Commands:**
```bash
# Deploy tenant
export SELLYOURSAAS_INSTANCE_NAME="test-01"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://test-01.$TENANT_DOMAIN"
export SELLYOURSAAS_VERSION="23.0.1"

./Scripts/deploy.sh test-01

# Vent på pods
sleep 30

# Verificer
kubectl get namespace tenant-test-01
kubectl get pods -n tenant-test-01
kubectl get all -n tenant-test-01
kubectl get ingress -n tenant-test-01
kubectl get resourcequota -n tenant-test-01
kubectl get networkpolicy -n tenant-test-01

# Tjek healthz (hvis ingress IP er tilgængelig)
INGRESS_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "127.0.0.1")
curl -k -fsS https://test-01.$TENANT_DOMAIN/healthz || echo "Healthz ikke tilgængelig (forventet i k3d)"
```

**Forventet:**
- Namespace `tenant-test-01` findes
- 2 pods (dolibarr + mariadb) kører
- Ingress, Service, ResourceQuota, NetworkPolicy findes
- Status-fil skrevet: `$STATUS_DIR/tenant-test-01.status` = "deployed"

**✅ PASS / ❌ FAIL:**

---

### Test 1b-02: Suspension

**Formål:** Verificere at suspension skalerer workloads til 0 og sletter CronJobs.

**Steps:**
1. Deploy en tenant
2. Suspender tenant
3. Verificer at workloads er scaled til 0
4. Verificer at CronJobs er slettet

**Commands:**
```bash
# Deploy først
./Scripts/deploy.sh test-02
sleep 15

# Suspender
./Scripts/suspend.sh test-02

# Verificer
DEPLOYMENT_REPLICAS=$(kubectl get deployment -n tenant-test-02 dolibarr -o jsonpath='{.spec.replicas}')
STATEFULSET_REPLICAS=$(kubectl get statefulset -n tenant-test-02 mariadb -o jsonpath='{.spec.replicas}')
CRONJOBS_COUNT=$(kubectl get cronjob -n tenant-test-02 --ignore-not-found | wc -l)

echo "Deployment replicas: $DEPLOYMENT_REPLICAS (forventet: 0)"
echo "StatefulSet replicas: $STATEFULSET_REPLICAS (forventet: 0)"
echo "CronJobs count: $CRONJOBS_COUNT (forventet: 0)"

# Tjek status-fil
cat "$STATUS_DIR/tenant-test-02.status"
```

**Forventet:**
- `DEPLOYMENT_REPLICAS` = 0
- `STATEFULSET_REPLICAS` = 0
- `CRONJOBS_COUNT` = 0
- Status-fil = "suspended"

**✅ PASS / ❌ FAIL:**

---

### Test 1b-03: Unsuspension

**Formål:** Verificere at unsuspension genskaber workloads og CronJobs.

**Steps:**
1. Deploy en tenant
2. Suspender tenant
3. Unsuspender tenant
4. Verificer at workloads er tilbage

**Commands:**
```bash
# Deploy
./Scripts/deploy.sh test-03
sleep 15

# Suspender
./Scripts/suspend.sh test-03
sleep 5

# Unsuspender
./Scripts/unsuspend.sh test-03
sleep 15

# Verificer
DEPLOYMENT_REPLICAS=$(kubectl get deployment -n tenant-test-03 dolibarr -o jsonpath='{.spec.replicas}')
STATEFULSET_REPLICAS=$(kubectl get statefulset -n tenant-test-03 mariadb -o jsonpath='{.spec.replicas}')
CRONJOBS_COUNT=$(kubectl get cronjob -n tenant-test-03 --ignore-not-found | wc -l)

echo "Deployment replicas: $DEPLOYMENT_REPLICAS (forventet: 1)"
echo "StatefulSet replicas: $STATEFULSET_REPLICAS (forventet: 1)"
echo "CronJobs count: $CRONJOBS_COUNT (forventet: > 0)"

# Tjek status-fil
cat "$STATUS_DIR/tenant-test-03.status"
```

**Forventet:**
- `DEPLOYMENT_REPLICAS` = 1
- `STATEFULSET_REPLICAS` = 1
- `CRONJOBS_COUNT` > 0
- Status-fil = "deployed"

**✅ PASS / ❌ FAIL:**

---

### Test 1b-04: Undeploy

**Formål:** Verificere at undeploy sletter namespace og values-fil.

**Steps:**
1. Deploy en tenant
2. Undeploy tenant
3. Verificer at namespace er slettet
4. Verificer at values-fil er slettet

**Commands:**
```bash
# Deploy
./Scripts/deploy.sh test-04
sleep 15

# Undeploy
./Scripts/undeploy.sh test-04
sleep 5

# Verificer
NAMESPACE_EXISTS=$(kubectl get namespace tenant-test-04 --ignore-not-found | wc -l)
VALUES_FILE_EXISTS=$(test -f "$VALUES_DIR/tenant-test-04.yaml" && echo "1" || echo "0")

echo "Namespace exists: $NAMESPACE_EXISTS (forventet: 0)"
echo "Values file exists: $VALUES_FILE_EXISTS (forventet: 0)"

# Tjek status-fil
cat "$STATUS_DIR/tenant-test-04.status"
```

**Forventet:**
- `NAMESPACE_EXISTS` = 0
- `VALUES_FILE_EXISTS` = 0
- Status-fil = "undeployed"

**✅ PASS / ❌ FAIL:**

---

### Test 1b-05: cert-manager Fornyelse under Suspension

**Formål:** **Kritisk test** - Verificere at cert-manager kan forny certifikater når tenant er suspended.

**Begrundelse:** Ifølge arkitektur §3.3: "cert-manager's HTTP-01-solver opretter sin egen midlertidige pod + service + Ingress-regel og er ikke afhængig af tenantens app-pods – fornyelse virker, så længe Ingress-ressourcen og cert-manager lever."

**Steps:**
1. Deploy en tenant
2. Vent på at certifikat er udstedt
3. Suspender tenant
4. Vent på cert-manager check interval (1 minut)
5. Verificer at certifikat fornyes

**Commands:**
```bash
# Deploy
./Scripts/deploy.sh cert-test-01

# Vent på certifikat (kan tage 30-60 sekunder)
sleep 45

# Tjek certifikat status
kubectl get certificate -n tenant-cert-test-01
kubectl describe certificate -n tenant-cert-test-01

# Suspender
./Scripts/suspend.sh cert-test-01
sleep 5

# Vent på cert-manager check (1 minut)
sleep 60

# Tjek certifikat status igen
CERT_STATUS=$(kubectl get certificate -n tenant-cert-test-01 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
CERT_NOT_AFTER=$(kubectl get certificate -n tenant-cert-test-01 -o jsonpath='{.status.notAfter}')

echo "Certificate status: $CERT_STATUS (forventet: True)"
echo "Certificate notAfter: $CERT_NOT_AFTER"

# Verificer at certifikat er gyldigt
if [[ "$CERT_STATUS" == "True" ]]; then
  echo "✅ cert-manager fornyelse under suspension VIRKER"
else
  echo "❌ cert-manager fornyelse under suspension FEJLEDE"
  kubectl describe certificate -n tenant-cert-test-01
fi
```

**Forventet:**
- `CERT_STATUS` = "True"
- Certifikat er gyldigt (notAfter > current time)

**✅ PASS / ❌ FAIL:**

---

### Test 1b-06: Deploy Fejler (Ugyldige Values)

**Formål:** Verificere at deploy fejler korrekt med ugyldige values.

**Steps:**
1. Opret ugyldige values (mangler domain)
2. Prøv at deploye
3. Verificer at fejl håndteres

**Commands:**
```bash
# Opret ugyldige values
cat > "$VALUES_DIR/tenant-fail-01.yaml" << 'EOF'
instance: "fail-01"
# Mangler domain
suspended: false
EOF

# Prøv at deploye (skal fejle)
./Scripts/deploy.sh fail-01 || echo "✅ Fejl håndteret korrekt"

# Tjek at ingen halvfærdig instans
NAMESPACE_EXISTS=$(kubectl get namespace tenant-fail-01 --ignore-not-found | wc -l)
echo "Namespace exists: $NAMESPACE_EXISTS (forventet: 0)"
```

**Forventet:**
- Deploy fejler med korrekt fejlmeddelelse
- Ingen namespace oprettet

**✅ PASS / ❌ FAIL:**

---

### Test 1b-07: Suspend Fejler (Release Findes Ikke)

**Formål:** Verificere at suspend fejler korrekt når release ikke findes.

**Commands:**
```bash
./Scripts/suspend.sh non-existent-tenant || echo "✅ Fejl håndteret korrekt"
```

**Forventet:**
- Fejlmeddelelse: "Kan ikke suspendere: release tenant-non-existent-tenant findes ikke"

**✅ PASS / ❌ FAIL:**

---

### Test 1b-08: Healthz Timeout

**Formål:** Verificere at healthz timeout håndteres korrekt.

**Commands:**
```bash
# Sæt timeout til 5 sekunder
export HEALTHZ_TIMEOUT=5

# Deploy (skal fejle på healthz check)
./Scripts/deploy.sh timeout-test-01 || echo "✅ Timeout håndteret korrekt"

# Tjek status
NAMESPACE_EXISTS=$(kubectl get namespace tenant-timeout-test-01 --ignore-not-found | wc -l)
echo "Namespace exists: $NAMESPACE_EXISTS"
```

**Forventet:**
- Deploy fejler på healthz check
- Namespace kan være oprettet (afhænger af hvornår timeout sker)

**✅ PASS / ❌ FAIL:**

---

### Test 1b-09: DB-pod Ikke Fundet

**Formål:** Verificere at beforeundeploy håndterer manglende DB-pod korrekt.

**Commands:**
```bash
# Deploy en tenant
./Scripts/deploy.sh db-test-01
sleep 15

# Slet DB-pod manuelt (simuler fejl)
kubectl delete pod -n tenant-db-test-01 -l app.kubernetes.io/component=db --ignore-not-found
sleep 2

# Prøv at køre beforeundeploy (skal springe dump over)
./Scripts/beforeundeploy.sh db-test-01 || echo "✅ Fejl håndteret korrekt"

# Tjek at status er skrevet
cat "$STATUS_DIR/tenant-db-test-01.status"
```

**Forventet:**
- Fejlmeddelelse: "Fandt ingen DB-pod... springer dump over"
- Status-fil = "preundeploy-backup-skipped"

**✅ PASS / ❌ FAIL:**

---

### Test 1b-10: DNS Automatisering

**Formål:** Verificere at DNS records oprettes og slettes korrekt.

**Forudsætning:** Cloudflare API er konfigureret og tilgængelig.

**Commands:**
```bash
# Deploy en tenant
./Scripts/deploy.sh dns-test-01
sleep 15

# Tjek DNS record (kræver dig/jq)
DNS_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=dns-test-01.$TENANT_DOMAIN" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].name // empty')

echo "DNS record: $DNS_RECORD (forventet: dns-test-01.$TENANT_DOMAIN)"

# Undeploy
./Scripts/undeploy.sh dns-test-01
sleep 5

# Tjek at DNS record er slettet
DNS_RECORD_AFTER=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=dns-test-01.$TENANT_DOMAIN" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].name // empty')

echo "DNS record after undeploy: $DNS_RECORD_AFTER (forventet: empty)"
```

**Forventet:**
- DNS record oprettet ved deploy
- DNS record slettet ved undeploy

**✅ PASS / ❌ FAIL:**

---

## 📊 Test Rapport

### Samlet Status

| Test ID | Test | Status | Noter |
|---------|------|--------|-------|
| 1b-01 | Normal deploy flow | [ ] | |
| 1b-02 | Suspension | [ ] | |
| 1b-03 | Unsuspension | [ ] | |
| 1b-04 | Undeploy | [ ] | |
| **1b-05** | **cert-manager fornyelse under suspension** | [ ] | **Kritisk** |
| 1b-06 | Deploy fejler (ugyldige values) | [ ] | |
| 1b-07 | Suspend fejler (release findes ikke) | [ ] | |
| 1b-08 | Healthz timeout | [ ] | |
| 1b-09 | DB-pod ikke fundet | [ ] | |
| 1b-10 | DNS automatisering | [ ] | |

**Total:** 0/10 tests bestået (0%)

---

## 🎯 Exit Kriterier

### Minimum (for at gå videre til fase 1c)

- [ ] **1b-01** Normal deploy flow ✅
- [ ] **1b-02** Suspension ✅
- [ ] **1b-03** Unsuspension ✅
- [ ] **1b-04** Undeploy ✅
- [ ] **1b-05** cert-manager fornyelse under suspension ✅ (**Kritisk**)
- [ ] Protokol-test (CI-niveau 1) grøn ✅

### Fuldt (anbefalet)

- [ ] Alle 10 tests bestået
- [ ] Fejlhåndtering tests bestået
- [ ] Dokumentation opdateret

---

## 📚 Referencer

- [Fase 1b - Installationstjekliste](Installationstjekliste.md)
- [Fase 1b - README](README.md)
- [Arkitektur Dokumentation](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
