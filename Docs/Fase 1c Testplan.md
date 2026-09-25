# Fase 1c - Testplan: Livscyklus og Gendannelse

## Formål

Verificere at:
1. **Rollback efter fejlet DB-migrering** fungerer (§3.5)
2. **Restore af én tenant** fungerer (§3.3)
3. **Secrets-flow** er end-to-end verificeret (§3.3.1)

## Testmatrix

| ID | Test | Type | Exit-kriterium | Status |
|----|------|------|----------------|--------|
| 1c-01 | Pre-migration snapshot | Funktionel | Snapshot uploadet til S3 | ⬜ |
| 1c-02 | Fejlet migrering + rollback | Funktionel | Tenant gendannet til tidligere version | ⬜ |
| 1c-03 | Restore fra backup | Funktionel | Tenant fungerer efter restore | ⬜ |
| 1c-04 | Secrets-flow (SealedSecret) | Funktionel | Alle secrets er SealedSecrets | ⬜ |
| 1c-05 | cert-manager fornyelse under suspension | Funktionel | Certifikater fornyes | ⬜ |

## Testprocedure

### Forudsætninger

- k3d-cluster kører (`k3d cluster create saas-test`)
- kubectl, helm, curl, jq, yq installeret
- MinIO (S3 mock) kører for backup-tests
- cert-manager installeret i clusteret

### Setup

```bash
# 1. Start cluster
k3d cluster create saas-test

# 2. Installer cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# 3. Installer MinIO (S3 mock)
docker run -d -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  --name minio \
  quay.io/minio/minio server /data --console-address ":9001"

# 4. Opret buckets
curl -X PUT http://localhost:9000/minioadmin/saasplatform-backups \
  -H "Host: localhost:9000"
curl -X PUT http://localhost:9000/minioadmin/pre-migration-backups \
  -H "Host: localhost:9000"

# 5. Eksportér miljøvariabler
export S3_ENDPOINT="http://localhost:9000"
export S3_BUCKET="saasplatform-backups"
export S3_ACCESS_KEY="minioadmin"
export S3_SECRET_KEY="minioadmin"
export CLOUDFLARE_API_TOKEN="test-token"
export CLOUDFLARE_ZONE_ID="test-zone"
```

## Test 1c-01: Pre-migration Snapshot

**Formål**: Verificere at pre-migration snapshot tages og uploades til S3.

**Steps**:
1. Deploy tenant med version 23.0.1
2. Kør migrate.sh med ny version 23.0.2
3. Verificer at snapshot er uploadet til S3

**Commands**:
```bash
# Deploy
./Scripts/deploy.sh test1

# Vent på pods
kubectl wait --for=condition=ready pod -n tenant-test1 --all --timeout=5m

# Opdater version
export SELLYOURSAAS_VERSION="23.0.2"

# Kør migrering
./Scripts/migrate.sh test1

# Verificer snapshot i S3
curl -I http://localhost:9000/saasplatform-backups/pre-migration-backups/tenant-test1/pre-migration-23.0.2-*.sql.gz \
  -H "Host: localhost:9000" \
  -u minioadmin:minioadmin
```

**Forventet**: HTTP 200, snapshot findes i S3

## Test 1c-02: Fejlet Migrering + Rollback

**Formål**: Verificere rollback-procedure efter fejlet DB-migrering.

**Steps**:
1. Deploy tenant med version 23.0.1
2. Simuler migrering til 23.0.2 med pre-migration snapshot
3. Simuler fejl under migrering
4. Kør rollback.sh
5. Verificer at tenant er tilbage på 23.0.1

**Commands**:
```bash
# Deploy
./Scripts/deploy.sh test1

# Vent på pods
kubectl wait --for=condition=ready pod -n tenant-test1 --all --timeout=5m

# Opdater values-fil til at simulere migrering
export SELLYOURSAAS_VERSION="23.0.2"

# Tag pre-migration snapshot
./Scripts/migrate.sh test1

# Simuler fejl: opdater image.tag men lad som om migreringen fejlede
# Manuelt: opdater values-filen til at have rollback flag
yq eval '.rollback.enabled = true' -i /tmp/saasplatform-values/tenant-test1.yaml > /tmp/values-new.yaml
yq eval '.rollback.targetVersion = "23.0.1"' -i /tmp/values-new.yaml > /tmp/values-new2.yaml
yq eval '.rollback.restoreFromSnapshot = "pre-migration-23.0.2-<timestamp>"' -i /tmp/values-new2.yaml > /tmp/saasplatform-values/tenant-test1.yaml

# Kør rollback
./Scripts/rollback.sh test1

# Verificer at tenant kører med gammel version
kubectl get pods -n tenant-test1 -l app=dolibarr
kubectl get deployment -n tenant-test1 dolibarr -o yaml | grep image

# Verificer healthz
./Scripts/cron.sh test1
```

**Forventet**: Tenant kører med version 23.0.1, healthz OK

## Test 1c-03: Restore fra Backup

**Formål**: Verificere restore-procedure (§3.3).

**Steps**:
1. Deploy tenant
2. Tag backup (manuelt eller via beforeundeploy)
3. Slet tenant
4. Kør restore-tenant.sh
5. Verificer at tenant fungerer

**Commands**:
```bash
# Deploy
./Scripts/deploy.sh test1

# Vent på pods
kubectl wait --for=condition=ready pod -n tenant-test1 --all --timeout=5m

# Tag backup
./Scripts/beforeundeploy.sh test1

# Slet tenant
./Scripts/undeploy.sh test1

# Vent på namespace er slettet
sleep 5

# Restore
./Scripts/restore-tenant.sh test1

# Verificer at tenant fungerer
kubectl get pods -n tenant-test1
./Scripts/cron.sh test1
```

**Forventet**: Tenant kører, healthz OK

## Test 1c-04: Secrets-flow Verification

**Formål**: Verificere SealedSecrets flow (§3.3.1).

**Steps**:
1. Deploy tenant
2. Verificer at alle secrets er SealedSecrets
3. Test password-reset flow

**Commands**:
```bash
# Deploy
./Scripts/deploy.sh test1

# Verificer secrets-flow
./Scripts/verify-secrets-flow.sh test1

# Tjek manuelt
kubectl get sealedsecret -n tenant-test1
kubectl get secret -n tenant-test1
```

**Forventet**: Ingen klartekst-secrets, alle er SealedSecrets

## Test 1c-05: cert-manager Fornyelse under Suspension

**Formål**: Verificere at cert-manager kan forny certifikater under suspension (§3.3).

**Steps**:
1. Deploy tenant med TLS
2. Suspender tenant
3. Vent på certifikat udløb (simuleret)
4. Verificer at certifikat fornyes

**Commands**:
```bash
# Deploy
./Scripts/deploy.sh test1

# Vent på certifikat
kubectl get certificate -n tenant-test1

# Suspender
./Scripts/suspend.sh test1

# Vent 1 minut (cert-manager check interval)
sleep 60

# Tjek certifikat status
kubectl describe certificate -n tenant-test1

# Tjek at certifikat er gyldigt
kubectl get certificate -n tenant-test1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

**Forventet**: Certificate status = True

## Acceptance Criteria

### Minimum (for at gå videre til fase 2)
- [ ] Test 1c-01 bestået (pre-migration snapshot)
- [ ] Test 1c-02 bestået (rollback)
- [ ] Test 1c-03 bestået (restore)

### Fuldt (anbefalet)
- [ ] Alle 5 tests bestået
- [ ] CI pipeline grøn

## Fejlhåndtering

### Hvis test fejler:

1. **Tjek logs**:
   ```bash
   kubectl logs -n tenant-test1 <pod>
   journalctl -u saasplatform-k8s
   ```

2. **Tjek ressourcer**:
   ```bash
   kubectl get all -n tenant-test1
   kubectl describe <resource> -n tenant-test1
   ```

3. **Manuel debug**:
   ```bash
   kubectl exec -it -n tenant-test1 <pod> -- sh
   ```

## Dokumentation

- [Arkitektur §3.3](Arkitektur.md#33-dataplane-dolibarr-erp-pr-tenant) - Dataplane details
- [Arkitektur §3.5](Arkitektur.md#35-opdatering-af-tenant-software) - Opdatering og rollback
- [Scripts/README.md](../Scripts/README.md) - Script dokumentation
