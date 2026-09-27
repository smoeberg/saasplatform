# Fase 1c - Installationstjekliste: Livscyklus og Gendannelse

**Formål:** Implementere og verificere livscyklus-management for Dolibarr-tenants.
**Exit-kriterier:** Rollback + Restore + Secrets-flow verificeret + CI-niveau 2 grøn.

---

## 📋 Checkliste

### ✅ 1. Backup Infrastructure

#### 1.1 MinIO (S3 Mock) - Development

- [ ] **MinIO container kører**
  ```bash
  docker ps | grep minio
  ```
- [ ] **Buckets oprettet**
  - [ ] `saasplatform-backups`
  - [ ] `pre-migration-backups`
- [ ] **Miljøvariabler sat**
  - [ ] `S3_ENDPOINT`
  - [ ] `S3_BUCKET`
  - [ ] `S3_ACCESS_KEY`
  - [ ] `S3_SECRET_KEY`
  - [ ] `S3_PRE_MIGRATION_BUCKET`

#### 1.2 Wasabi (Production S3)

- [ ] **Wasabi bucket oprettet**
  - [ ] `saasplatform-backups`
  - [ ] `pre-migration-backups`
- [ ] **Access keys oprettet**
- [ ] **Miljøvariabler sat** (se ovenfor)

---

### ✅ 2. Velero Setup

- [ ] **Velero CLI installeret**
  ```bash
  velero version
  ```
- [ ] **Velero installeret i clusteret**
  ```bash
  kubectl get pods -n velero
  ```
- [ ] **Velero credentials konfigureret**
  ```bash
  ls -la Infrastructure/velero/velero-credentials
  ```
- [ ] **Velero backup location konfigureret**
  ```bash
  velero backup-location get
  ```
- [ ] **Velero snapshot location konfigureret**
  ```bash
  velero snapshot-location get
  ```

---

### ✅ 3. Helm Chart Konfiguration

- [ ] **erp-tenant chart opdateret**
  - [ ] Pre-migration snapshot CronJob til stede
  - [ ] Backup CronJob til stede
  - [ ] Rollback ConfigMap til stede
- [ ] **Values.yaml opdateret**
  - [ ] `backup.enabled: true`
  - [ ] `backup.preMigration.enabled: true`
  - [ ] `backup.s3Enabled: true`
  - [ ] `backup.bucket` sat

---

### ✅ 4. Scripts Konfiguration

- [ ] **migrate.sh**
  - [ ] Pre-migration snapshot funktion implementeret
  - [ ] Migreringslogik implementeret
  - [ ] Fejlhåndtering implementeret

- [ ] **rollback.sh**
  - [ ] Rollback til tidligere version implementeret
  - [ ] Snapshot restore funktion implementeret
  - [ ] Healthz check efter rollback

- [ ] **restore-tenant.sh**
  - [ ] Restore fra Velero backup implementeret
  - [ ] Restore fra S3 backup implementeret
  - [ ] Verifikation implementeret

- [ ] **verify-secrets-flow.sh**
  - [ ] SealedSecrets verifikation implementeret
  - [ ] Password-reset flow testet

---

## 🧪 Test Scenarier

### 📝 5. Pre-migration Snapshot Tests (1c-01)

| # | Test | Beskrivelse | Status | Noter |
|---|------|-------------|--------|-------|
| 1 | Deploy → pre-migration snapshot → S3 upload | Tag snapshot før migrering | [ ] | |
| 2 | Pre-migration snapshot med custom version | Test med forskellige versioner | [ ] | |
| 3 | Pre-migration snapshot fejler (S3 nedbrud) | Test fejlhåndtering | [ ] | |

**Commands:**
```bash
# Test 1
./Scripts/deploy.sh snapshot-test-01
export SELLYOURSAAS_VERSION="23.0.2"
./Scripts/migrate.sh snapshot-test-01 --pre-migration-only

# Verificer
curl -I "$S3_ENDPOINT/$S3_PRE_MIGRATION_BUCKET/snapshot-test-01/pre-migration-*.sql.gz" \
  -H "Host: $S3_BUCKET.$S3_ENDPOINT" \
  -u $S3_ACCESS_KEY:$S3_SECRET_KEY
```

---

### 📝 6. Fejlet Migrering + Rollback Tests (1c-02)

| # | Test | Beskrivelse | Status | Noter |
|---|------|-------------|--------|-------|
| 1 | Migrering til ny version → fejl → rollback | Test rollback procedure | [ ] | |
| 2 | Rollback med snapshot restore | Verificer data integritet | [ ] | |
| 3 | Rollback uden snapshot | Test fallback procedure | [ ] | |
| 4 | Rollback til flere versioner tilbage | Test version rotation | [ ] | |

**Commands:**
```bash
# Test 1
./Scripts/deploy.sh rollback-test-01
./Scripts/migrate.sh rollback-test-01 --pre-migration-only

# Simuler fejl
kubectl set image -n tenant-rollback-test-01 deployment/dolibarr dolibarr=ghcr.io/smoeberg/dolibarr:invalid

# Kør rollback
./Scripts/rollback.sh rollback-test-01 --target-version 23.0.1

# Verificer
kubectl get deployment -n tenant-rollback-test-01 dolibarr -o yaml | grep image
./Scripts/cron.sh rollback-test-01
```

---

### 📝 7. Restore Tests (1c-03)

| # | Test | Beskrivelse | Status | Noter |
|---|------|-------------|--------|-------|
| 1 | Velero backup → restore | Test natlig backup | [ ] | |
| 2 | S3 backup → restore | Test manuel backup | [ ] | |
| 3 | Restore til ny namespace | Test migration scenario | [ ] | |
| 4 | Restore med delvis data | Test data integritet | [ ] | |

**Commands:**
```bash
# Test 1 (Velero)
./Scripts/deploy.sh restore-test-01
velero backup create test-restore-backup --include-namespaces tenant-restore-test-01 --wait
./Scripts/undeploy.sh restore-test-01
velero restore create --from-backup test-restore-backup --wait
kubectl get pods -n tenant-restore-test-01
./Scripts/cron.sh restore-test-01

# Test 2 (S3)
./Scripts/deploy.sh restore-s3-test-01
./Scripts/beforeundeploy.sh restore-s3-test-01  # Tager backup
./Scripts/undeploy.sh restore-s3-test-01
./Scripts/restore-tenant.sh restore-s3-test-01
./Scripts/cron.sh restore-s3-test-01
```

---

### 📝 8. Secrets-Flow Tests (1c-04)

| # | Test | Beskrivelse | Status | Noter |
|---|------|-------------|--------|-------|
| 1 | SealedSecrets oprettet ved deploy | Verificer ingen klartekst | [ ] | |
| 2 | Password-reset flow | Test recreateauthorizedkeys.sh | [ ] | |
| 3 | Secrets rotation | Test flere password-resets | [ ] | |
| 4 | SealedSecrets controller nedbrud | Test fejlhåndtering | [ ] | |

**Commands:**
```bash
# Test 1
./Scripts/deploy.sh secrets-test-01
kubectl get sealedsecret -n tenant-secrets-test-01
kubectl get secret -n tenant-secrets-test-01 -o yaml | grep -v encryptedData | grep -i password
# Forventet: Ingen klartekst

# Test 2
./Scripts/recreateauthorizedkeys.sh secrets-test-01
kubectl get sealedsecret -n tenant-secrets-test-01
kubectl get pods -n tenant-secrets-test-01 -w  # Vent på restart
```

---

### 📝 9. cert-manager Fornyelse Tests (1c-05)

| # | Test | Beskrivelse | Status | Noter |
|---|------|-------------|--------|-------|
| 1 | Fornyelse under suspension | **Kritisk test** | [ ] | Gentaget fra fase 1b |
| 2 | Fornyelse ved certifikat udløb | Test automatisk fornyelse | [ ] | |
| 3 | Fornyelse med DNS fejl | Test fejlhåndtering | [ ] | |

**Commands:**
```bash
# Se Fase 1b Testplan for detaljer
./Scripts/deploy.sh cert-test-01
sleep 30  # Vent på certifikat
./Scripts/suspend.sh cert-test-01
sleep 60  # Vent på fornyelse
CERT_STATUS=$(kubectl get certificate -n tenant-cert-test-01 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[[ "$CERT_STATUS" == "True" ]] && echo "✅ PASS"
```

---

## 📊 Test Resultater

### Samlet Status

| Kategori | Total | Bestået | Fejlet | % |
|----------|-------|---------|--------|---|
| Pre-migration Snapshot | 3 | 0 | 0 | 0% |
| Fejlet Migrering + Rollback | 4 | 0 | 0 | 0% |
| Restore | 4 | 0 | 0 | 0% |
| Secrets-Flow | 4 | 0 | 0 | 0% |
| cert-manager Fornyelse | 3 | 0 | 0 | 0% |
| **Total** | **18** | **0** | **0** | **0%** |

---

## ✅ Exit Kriterier

### Minimum (for at gå videre til fase 2)

- [ ] **1c-01** Pre-migration snapshot fungerer
- [ ] **1c-02** Fejlet migrering + rollback fungerer
- [ ] **1c-03** Restore fra backup fungerer
- [ ] **1c-04** Secrets-flow verificeret

### Fuldt (anbefalet)

- [ ] Alle 18 tests bestået
- [ ] CI-niveau 2 (integrations-test) grøn
- [ ] Dokumentation opdateret
- [ ] Runbook for restore oprettet

---

## 📚 Dokumentation

- [Fase 1c - README](README.md)
- [Arkitektur Dokumentation](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
- [Fase 1b - Testplan](../Fase1b/Testplan.md) (cert-manager test)

---

## 🔧 Fejlfinding

Se [README.md](README.md#11-fejlfinding) for detaljeret fejlfinding.

---

## 📌 Noter

- **Pre-migration snapshots** gemmes separat fra natlige backups
- **Rollback** kræver pre-migration snapshot for DB-migreringer
- **Restore** kan gøres fra både Velero og S3 backups
- **Secrets-flow** skal verificeres end-to-end (ingen klartekst)
- **cert-manager fornyelse** skal virke under suspension (kritisk)
