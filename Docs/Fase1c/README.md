# Fase 1c - Livscyklus og Gendannelse

## Formål

Verificere og implementere **livscyklus-management** for Dolibarr-tenants i Kubernetes:
- **Opdatering** af tenant-software (ny version)
- **Rollback** efter fejlet DB-migrering
- **Restore** af tenant fra backup
- **Secrets-flow** end-to-end verifikation
- **Backup** strategier (natlig, pre-migration, retention)

**Exit-kriterier:**
- Rollback efter fejlet DB-migrering fungerer
- Restore af én tenant fungerer
- Secrets-flow er end-to-end verificeret
- Integrations-test (CI-niveau 2) grøn

---

## Overblik

Fase 1c bygger oven på fase 1b (K8s-grundintegration) og tilføjer:
1. **Migrering** af Dolibarr versioner med pre-migration snapshots
2. **Rollback** procedure ved fejl
3. **Backup & Restore** med Velero og S3
4. **Secrets-flow** verifikation (SealedSecrets)

---

## Arkitektur Reference

Se [Arkitektur.md](../Arkitektur.md) for:
- §3.3: Dataplane (Backup, Restore, Suspension)
- §3.5: Opdatering af tenant-software (Canary, Rollback)
- §3.3.1: Secrets-flow

---

## Forudsætninger

- [ ] Fase 1b er færdig (K8s deployment fungerer)
- [ ] k3s cluster kører med Traefik, cert-manager, SealedSecrets
- [ ] K8s-runner VM er opsat
- [ ] MinIO (S3 mock) eller Wasabi er konfigureret
- [ ] Velero er installeret i clusteret
- [ ] Helm chart (erp-tenant) er deployet

---

## 1. Backup Infrastructure

### 1.1 MinIO (S3 Mock) Setup

- [ ] **Installer MinIO** (for development/testing)
  ```bash
  docker run -d -p 9000:9000 -p 9001:9001 \
    -e MINIO_ROOT_USER=minioadmin \
    -e MINIO_ROOT_PASSWORD=minioadmin \
    --name minio \
    quay.io/minio/minio server /data --console-address ":9001"
  ```

- [ ] **Opret buckets**
  ```bash
  # Saasplatform backups (natlige)
  curl -X PUT http://localhost:9000/minioadmin/saasplatform-backups \
    -H "Host: localhost:9000"
  
  # Pre-migration backups
  curl -X PUT http://localhost:9000/minioadmin/pre-migration-backups \
    -H "Host: localhost:9000"
  ```

- [ ] **Konfigurer miljøvariabler**
  ```bash
  export S3_ENDPOINT="http://localhost:9000"
  export S3_BUCKET="saasplatform-backups"
  export S3_ACCESS_KEY="minioadmin"
  export S3_SECRET_KEY="minioadmin"
  export S3_PRE_MIGRATION_BUCKET="pre-migration-backups"
  ```

### 1.2 Wasabi (Production S3)

- [ ] **Opret Wasabi bucket**
  - Bucket navn: `saasplatform-backups`
  - Bucket navn: `pre-migration-backups`
  - Region: `eu-central-1` (eller andet passende)

- [ ] **Opret access keys**
  - Access Key ID
  - Secret Access Key

- [ ] **Konfigurer miljøvariabler**
  ```bash
  export S3_ENDPOINT="https://s3.eu-central-1.wasabisys.com"
  export S3_BUCKET="saasplatform-backups"
  export S3_ACCESS_KEY="YOUR_ACCESS_KEY"
  export S3_SECRET_KEY="YOUR_SECRET_KEY"
  export S3_PRE_MIGRATION_BUCKET="pre-migration-backups"
  ```

---

## 2. Velero Setup

### 2.1 Installer Velero CLI

- [ ] **Download Velero**
  ```bash
  wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
  tar -xvf velero-v1.12.0-linux-amd64.tar.gz
  sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/
  rm -rf velero-v1.12.0-linux-amd64 velero-v1.12.0-linux-amd64.tar.gz
  ```

### 2.2 Installer Velero i Clusteret

- [ ] **Opret credentials fil**
  ```bash
  mkdir -p Infrastructure/velero
  cat > Infrastructure/velero/velero-credentials << 'EOF'
  [default]
  aws_access_key_id = minioadmin
  aws_secret_access_key = minioadmin
  EOF
  ```

- [ ] **Installer Velero**
  ```bash
  velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.4.0 \
    --bucket $S3_BUCKET \
    --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=$S3_ENDPOINT \
    --snapshot-location-config region=us-east-1 \
    --secret-file ./Infrastructure/velero/velero-credentials \
    --namespace velero \
    --wait
  ```

- [ ] **Verificer installation**
  ```bash
  kubectl get pods -n velero
  velero version
  ```

---

## 3. Pre-migration Snapshot

### 3.1 Konfigurer Pre-migration CronJob

Helm chartet (`erp-tenant`) inkluderer allerede en **pre-migration snapshot CronJob** (se `templates/70-cronjob-backup.yaml`).

- [ ] **Aktivér pre-migration snapshot**
  ```yaml
  # I values.yaml
  dolibarr:
    migration:
      enabled: true
      preMigrationSnapshot: ""
  backup:
    preMigration:
      enabled: true
      s3Enabled: true
      bucket: "pre-migration-backups"
  ```

- [ ] **Manuelt trigger pre-migration snapshot**
  ```bash
  # Opdater values-fil for tenant
  yq eval '.dolibarr.migration.enabled = true' -i $VALUES_DIR/tenant-{instance}.yaml
  yq eval '.dolibarr.migration.preMigrationSnapshot = ""' -i $VALUES_DIR/tenant-{instance}.yaml
  
  # Trigger CronJob manuelt
  kubectl create job --from=cronjob/pre-migration-snapshot -n tenant-{instance}
  ```

### 3.2 Test Pre-migration Snapshot

- [ ] **Deploy tenant med version 23.0.1**
  ```bash
  export SELLYOURSAAS_VERSION="23.0.1"
  ./Scripts/deploy.sh test-migration-01
  ```

- [ ] **Trigger pre-migration snapshot**
  ```bash
  export SELLYOURSAAS_VERSION="23.0.2"
  ./Scripts/migrate.sh test-migration-01
  ```

- [ ] **Verificer snapshot i S3**
  ```bash
  # For MinIO
  curl -I http://localhost:9000/$S3_PRE_MIGRATION_BUCKET/test-migration-01/pre-migration-23.0.2-*.sql.gz \
    -H "Host: localhost:9000" \
    -u $S3_ACCESS_KEY:$S3_SECRET_KEY
  
  # For Wasabi
  aws s3 --endpoint-url=$S3_ENDPOINT ls s3://$S3_PRE_MIGRATION_BUCKET/test-migration-01/
  ```

---

## 4. Migrering og Rollback

### 4.1 Migreringsprocedure

Ifølge [Arkitektur.md §3.5](../Arkitektur.md#35-opdatering-af-tenant-software):

1. **Pre-migration snapshot** tages før migrering
2. **Migrering** køres (DB schema opdatering)
3. **Nyt image** deployes
4. **Healthz check** verificeres

### 4.2 Rollback Procedure

- [ ] **Manuelt rollback** (ifølge arkitektur §3.5.2)
  ```bash
  # 1. Gendan pre-migration snapshot
  ./Scripts/restore-tenant.sh test-migration-01 --from-snapshot pre-migration-23.0.2-{timestamp}
  
  # 2. Rollback til tidligere version
  export SELLYOURSAAS_VERSION="23.0.1"
  ./Scripts/rollback.sh test-migration-01
  ```

- [ ] **Automatisk rollback** (via Helm chart)
  ```yaml
  # I values.yaml
  rollback:
    enabled: true
    targetVersion: "23.0.1"
    restoreFromSnapshot: "pre-migration-23.0.2-{timestamp}"
  ```
  ```bash
  helm upgrade tenant-{instance} Helm/erp-tenant -n tenant-{instance} -f values.yaml
  ```

### 4.3 Test Fejlet Migrering + Rollback

**Formål:** Verificere at rollback fungerer efter fejlet DB-migrering.

**Steps:**
1. Deploy tenant med version 23.0.1
2. Tag pre-migration snapshot
3. Simuler fejl under migrering
4. Kør rollback
5. Verificer at tenant er tilbage på 23.0.1

**Commands:**
```bash
# 1. Deploy med version 23.0.1
./Scripts/deploy.sh rollback-test-01
sleep 15

# 2. Tag pre-migration snapshot
./Scripts/migrate.sh rollback-test-01 --pre-migration-only
sleep 5

# 3. Simuler migrering til 23.0.2 (med fejl)
# Manuelt: opdater image.tag i values-filen
kubectl set image -n tenant-rollback-test-01 deployment/dolibarr dolibarr=ghcr.io/smoeberg/dolibarr:23.0.2

# 4. Simuler fejl (slet DB-pod for at simulere korruption)
kubectl delete pod -n tenant-rollback-test-01 -l app=mariadb --force --grace-period=0
sleep 5

# 5. Kør rollback
./Scripts/rollback.sh rollback-test-01 --target-version 23.0.1 --snapshot pre-migration-23.0.2-{timestamp}

# 6. Verificer
kubectl get pods -n tenant-rollback-test-01
kubectl get deployment -n tenant-rollback-test-01 dolibarr -o yaml | grep image

# Tjek healthz
./Scripts/cron.sh rollback-test-01
```

**Forventet:**
- Tenant kører med version 23.0.1
- Healthz check OK
- Data intakt

---

## 5. Restore fra Backup

### 5.1 Natlig Backup (Velero)

- [ ] **Konfigurer Velero backup schedule**
  ```bash
  # Opret backup schedule (natlig kl. 03:00)
  cat > Infrastructure/velero/daily-backup-schedule.yaml << 'EOF'
  apiVersion: velero.io/v1
  kind: Schedule
  metadata:
    name: daily-backup
    namespace: velero
  spec:
    schedule: "0 3 * * *"
    template:
      ttl: 24h
      includedNamespaces:
        - tenant-*
  EOF
  
  kubectl apply -f Infrastructure/velero/daily-backup-schedule.yaml
  ```

- [ ] **Manuelt backup**
  ```bash
  velero backup create daily-{date +%Y%m%d} \
    --include-namespaces tenant-* \
    --ttl 7d
  ```

### 5.2 Restore Procedure

Ifølge [Arkitektur.md §3.3](../Arkitektur.md#33-dataplane-dolibarr-erp-pr-tenant):

**Restore-runbook (rækkefølge):**
1. Opret frisk namespace + helm-install med **ingen** data (pods stoppet)
2. Indlæs DB-dump (seneste konsistente punkt, valgt pr. tidspunkt)
3. Velero-restore af PVC (documents)
4. Start pods; verificér `/healthz` + login; varsel om manglende match mellem documents og DB

- [ ] **Restore fra Velero backup**
  ```bash
  # 1. Slet tenant (hvis den findes)
  ./Scripts/undeploy.sh restore-test-01
  sleep 5
  
  # 2. Restore fra backup
  velero restore create --from-backup daily-20260927 \
    --include-namespaces tenant-restore-test-01 \
    --wait
  
  # 3. Verificer
  kubectl get pods -n tenant-restore-test-01
  ./Scripts/cron.sh restore-test-01
  ```

- [ ] **Restore fra S3 backup (manuelt)**
  ```bash
  # 1. Download backup fra S3
  aws s3 --endpoint-url=$S3_ENDPOINT cp s3://$S3_BUCKET/restore-test-01/backup-20260927.sql.gz /tmp/
  
  # 2. Deploy tenant uden data
  ./Scripts/deploy.sh restore-test-01
  sleep 10
  
  # 3. Restore DB
  kubectl exec -n tenant-restore-test-01 pod/mariadb-0 -- bash -c "
    zcat /tmp/backup-20260927.sql.gz | mysql -u \$MARIADB_USER -p\$MARIADB_PASSWORD dolibarr
  " || true
  
  # 4. Restart pods
  kubectl rollout restart deployment/dolibarr -n tenant-restore-test-01
  
  # 5. Verificer
  ./Scripts/cron.sh restore-test-01
  ```

---

## 6. Secrets-Flow Verifikation

### 6.1 SealedSecrets Flow

Ifølge [Arkitektur.md §3.3.1](../Arkitektur.md#331-instancenamespace-mapping-og-secrets-flow):

**Secrets-flow (fase 1):**
1. Runneren genererer secrets lokalt (DB-password, app-secrets) ved første deploy
2. SealedSecret oprettes via `kubeseal` og apply'es — **klartekst slettes straks** (genereres aldrig gemt på runneren)
3. Password-reset fra SellYourSaaS-admin: runner genererer ny secret → ny SealedSecret → `helm upgrade` → restart af pod

- [ ] **Test SealedSecrets flow**
  ```bash
  # 1. Deploy tenant
  ./Scripts/deploy.sh secrets-test-01
  
  # 2. Tjek at secrets er SealedSecrets
  kubectl get sealedsecret -n tenant-secrets-test-01
  kubectl get secret -n tenant-secrets-test-01
  
  # 3. Verificer at der ikke er klartekst-secrets
  kubectl get secret -n tenant-secrets-test-01 -o yaml | grep -v "encryptedData" | grep -i password
  
  # Forventet: Ingen klartekst passwords
  ```

- [ ] **Test password-reset flow**
  ```bash
  # 1. Simuler password-reset (kald recreateauthorizedkeys.sh)
  ./Scripts/recreateauthorizedkeys.sh secrets-test-01
  
  # 2. Tjek at nye SealedSecrets er oprettet
  kubectl get sealedsecret -n tenant-secrets-test-01
  
  # 3. Tjek at pods er restarted
  kubectl get pods -n tenant-secrets-test-01 -w
  ```

---

## 7. Test Scenarier

### 7.1 Pre-migration Snapshot Test

| ID | Test | Status | Noter |
|----|------|--------|-------|
| 1c-01 | Deploy tenant → tag pre-migration snapshot → verificer i S3 | [ ] | |

**Commands:**
```bash
./Scripts/deploy.sh snapshot-test-01
export SELLYOURSAAS_VERSION="23.0.2"
./Scripts/migrate.sh snapshot-test-01 --pre-migration-only

# Verificer i S3
curl -I "$S3_ENDPOINT/$S3_PRE_MIGRATION_BUCKET/snapshot-test-01/pre-migration-23.0.2-*.sql.gz" \
  -H "Host: $S3_BUCKET.$S3_ENDPOINT" \
  -u $S3_ACCESS_KEY:$S3_SECRET_KEY
```

---

### 7.2 Fejlet Migrering + Rollback Test

| ID | Test | Status | Noter |
|----|------|--------|-------|
| 1c-02 | Deploy → pre-migration snapshot → fejl under migrering → rollback → verificer version | [ ] | |

**Commands:**
```bash
# Deploy
./Scripts/deploy.sh rollback-test-01

# Tag snapshot
./Scripts/migrate.sh rollback-test-01 --pre-migration-only

# Simuler fejl (opdater image til ugyldig version)
kubectl set image -n tenant-rollback-test-01 deployment/dolibarr dolibarr=ghcr.io/smoeberg/dolibarr:invalid-version

# Vent på fejl
sleep 10

# Kør rollback
./Scripts/rollback.sh rollback-test-01 --target-version 23.0.1

# Verificer
kubectl get deployment -n tenant-rollback-test-01 dolibarr -o yaml | grep image
./Scripts/cron.sh rollback-test-01
```

---

### 7.3 Restore Test

| ID | Test | Status | Noter |
|----|------|--------|-------|
| 1c-03 | Deploy → backup → undeploy → restore → verificer | [ ] | |

**Commands:**
```bash
# Deploy
./Scripts/deploy.sh restore-test-01
sleep 15

# Tag backup (manuelt)
velero backup create test-restore-backup \
  --include-namespaces tenant-restore-test-01 \
  --wait

# Undeploy
./Scripts/undeploy.sh restore-test-01
sleep 5

# Restore
velero restore create --from-backup test-restore-backup \
  --wait \
  --timeout 10m

# Verificer
kubectl get pods -n tenant-restore-test-01
./Scripts/cron.sh restore-test-01
```

---

### 7.4 Secrets-Flow Test

| ID | Test | Status | Noter |
|----|------|--------|-------|
| 1c-04 | Deploy → verificer SealedSecrets → password-reset → verificer nye secrets | [ ] | |

**Commands:**
```bash
# Deploy
./Scripts/deploy.sh secrets-test-01

# Tjek secrets
kubectl get sealedsecret -n tenant-secrets-test-01
kubectl get secret -n tenant-secrets-test-01

# Password-reset
./Scripts/recreateauthorizedkeys.sh secrets-test-01

# Tjek nye secrets
kubectl get sealedsecret -n tenant-secrets-test-01
```

---

### 7.5 cert-manager Fornyelse under Suspension Test

| ID | Test | Status | Noter |
|----|------|--------|-------|
| 1c-05 | Deploy → vent på certifikat → suspend → vent 1 min → tjek fornyelse | [ ] | **Gentaget fra fase 1b** |

**Commands:**
```bash
# Se Fase 1b Testplan for detaljer
```

---

## 8. Exit Kriterier

### Minimum (for at gå videre til fase 2)

- [ ] **1c-01** Pre-migration snapshot fungerer
- [ ] **1c-02** Fejlet migrering + rollback fungerer
- [ ] **1c-03** Restore fra backup fungerer
- [ ] **1c-04** Secrets-flow verificeret

### Fuldt (anbefalet)

- [ ] Alle 5 tests bestået
- [ ] CI-niveau 2 (integrations-test) grøn
- [ ] Dokumentation opdateret
- [ ] Runbook for restore oprettet

---

## 9. Checkliste

### Infrastructure

- [ ] MinIO/Wasabi konfigureret
- [ ] S3 buckets oprettet
- [ ] Velero installeret i clusteret
- [ ] Velero backup schedule oprettet
- [ ] SealedSecrets controller installeret

### Konfiguration

- [ ] Miljøvariabler sat (S3_ENDPOINT, S3_BUCKET, etc.)
- [ ] Helm chart opdateret med backup/rollback support
- [ ] Scripts opdateret (migrate.sh, rollback.sh, restore-tenant.sh)

### Tests

- [ ] 1c-01: Pre-migration snapshot test bestået
- [ ] 1c-02: Fejlet migrering + rollback test bestået
- [ ] 1c-03: Restore test bestået
- [ ] 1c-04: Secrets-flow test bestået
- [ ] 1c-05: cert-manager fornyelse test bestået

### Dokumentation

- [ ] Test resultater dokumenteret
- [ ] Fejlfinding guide oprettet
- [ ] Runbook for restore oprettet

---

## 10. Fejlfinding

### Velero Fejl

```bash
# Tjek Velero pods
kubectl get pods -n velero

# Tjek Velero logs
kubectl logs -n velero deployment/velero

# Tjek backup status
velero backup get
velero backup describe <backup-name>

# Tjek restore status
velero restore get
velero restore describe <restore-name>
```

### S3 Fejl

```bash
# Test S3 adgang
curl -v "$S3_ENDPOINT/$S3_BUCKET/" \
  -u $S3_ACCESS_KEY:$S3_SECRET_KEY

# Test MinIO
mc alias set minio http://localhost:9000 minioadmin minioadmin
mc ls minio/$S3_BUCKET
```

### Rollback Fejl

```bash
# Tjek rollback logs
kubectl logs -n tenant-{instance} job/rollback-{timestamp}

# Tjek Helm release historik
helm history tenant-{instance} -n tenant-{instance}

# Tjek values-fil
cat $VALUES_DIR/tenant-{instance}.yaml
```

### Secrets Fejl

```bash
# Tjek SealedSecrets controller logs
kubectl logs -n kube-system -l name=sealed-secrets-controller

# Tjek SealedSecrets status
kubectl get sealedsecret -A
kubectl describe sealedsecret -n tenant-{instance} tenant-db
```

---

## 11. Ressourcer

- [Arkitektur Dokumentation](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
- [Velero Dokumentation](https://velero.io/docs/)
- [MinIO Dokumentation](https://min.io/docs/)
- [Wasabi Dokumentation](https://wasabi.com/docs/)
- [SealedSecrets Dokumentation](https://github.com/bitnami-labs/sealed-secrets)

---

## 12. Relaterede Scripts

| Script | Beskrivelse |
|--------|-------------|
| `migrate.sh` | Håndterer migrering og pre-migration snapshots |
| `rollback.sh` | Udfører rollback til tidligere version |
| `restore-tenant.sh` | Restorer tenant fra backup |
| `beforeundeploy.sh` | Tager backup før undeploy |
| `verify-secrets-flow.sh` | Verificerer secrets-flow |
