# Velero Backup - Opsætningsguide

## Overblik

Velero bruges til:
- **Natlige backups** af alle tenant-resources (Deployments, StatefulSets, PVCs, etc.)
- **Point-in-time recovery** for tenants
- **Disaster recovery** (restore til nyt cluster)
- **Migration** mellem clusters

## Forudsætninger

- k3s cluster (se [Infrastructure/k3s](../k3s))
- Wasabi S3 bucket (eller anden S3-kompatibel storage)
- kubectl adgang til clusteret

## Installation

### 1. Installer Velero CLI

```bash
# Download Velero
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xvf velero-v1.12.0-linux-amd64.tar.gz
sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/
rm -rf velero-v1.12.0-linux-amd64 velero-v1.12.0-linux-amd64.tar.gz

# Verificer
velero version
```

### 2. Installer Velero i clusteret

```bash
# Opret namespace
kubectl create namespace velero

# Installer Velero med Wasabi plugin
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.4.0 \
  --bucket saasplatform-backups \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=https://s3.wasabisys.com \
  --snapshot-location-config region=us-east-1 \
  --secret-file ./Infrastructure/velero/velero-credentials
  --namespace velero \
  --wait

# Verificer installation
kubectl get pods -n velero
kubectl get deployment -n velero velero
```

### 3. Konfigurer credentials

Opret filen `Infrastructure/velero/velero-credentials`:

```ini
[default]
aws_access_key_id = YOUR_WASABI_ACCESS_KEY
aws_secret_access_key = YOUR_WASABI_SECRET_KEY
```

**Sikkerhed**: Sæt korrekte permissions:
```bash
chmod 600 Infrastructure/velero/velero-credentials
```

### 4. Opret BackupStorageLocation og VolumeSnapshotLocation

```bash
# BackupStorageLocation (for etcd snapshots)
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: wasabi
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: saasplatform-backups
    prefix: ""
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: "https://s3.wasabisys.com"
EOF

# VolumeSnapshotLocation (for PVC snapshots)
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: VolumeSnapshotLocation
metadata:
  name: wasabi
  namespace: velero
spec:
  provider: aws
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: "https://s3.wasabisys.com"
EOF
```

### 5. Konfigurer backup schedule

```bash
# Natlig backup af alle tenants (kl. 03:00)
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: nightly-backup
  namespace: velero
spec:
  schedule: "0 3 * * *"
  template:
    ttl: 24h
    storageLocation: wasabi
    volumeSnapshotLocations:
      - wasabi
    includeNamespaces:
      - tenant-*
    excludeResources:
      - nodes
      - events
      - events.k8s.io
      - backups.velero.io
      - restores.velero.io
      - resticrepositories
    snapshotVolumes: true
    labels:
      saasplatform.io/backup: nightly
EOF
```

### 6. Konfigurer retention policy

```bash
# Behold backups i 7 dage (standard) eller 30 dage (premium)
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: wasabi
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: saasplatform-backups
    prefix: ""
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: "https://s3.wasabisys.com"
EOF

# Retention policy (håndhæves via TTL i Schedule)
# Standard: 7 dage, Premium: 30 dage
```

## Tenant-specifikke backups

### Backup af enkelt tenant

```bash
# Backup af en specifik tenant
velero backup create tenant-backup \
  --include-namespaces tenant-12345 \
  --storage-location wasabi \
  --volume-snapshot-locations wasabi \
  --ttl 24h \
  --labels saasplatform.io/tenant=12345

# Tjek backup status
velero backup get tenant-backup
velero backup describe tenant-backup
```

### Pre-migration snapshot

Se [Scripts/migrate.sh](../../Scripts/migrate.sh) for automatisk pre-migration snapshot.

## Restore

### Restore af enkelt tenant

```bash
# Find backup
velero backup get --selector saasplatform.io/tenant=12345

# Restore
velero restore create --from-backup <backup-name> \
  --namespace-mappings tenant-12345:tenant-12345 \
  --wait

# Tjek restore status
velero restore get <restore-name>
velero restore describe <restore-name>
```

### Restore til nyt cluster (disaster recovery)

```bash
# 1. Installer Velero på nyt cluster
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.4.0 \
  --bucket saasplatform-backups \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=https://s3.wasabisys.com \
  --snapshot-location-config region=us-east-1 \
  --secret-file ./Infrastructure/velero/velero-credentials \
  --namespace velero

# 2. Restore alle tenants
velero restore create --from-backup nightly-backup-<date> \
  --include-namespaces tenant-* \
  --wait
```

## DB-dump Integration

### Natlig DB-dump (udover Velero)

Velero tager snapshots af PVCs, men for DB-konsistens køres der også natlig `mysqldump`:

```bash
# CronJob for natlig DB-dump (per tenant)
# Se: Helm/templates/cronjob.yaml

# Eller manuelt:
kubectl exec -n tenant-12345 <mariadb-pod> -- \
  mysqldump --single-transaction --all-databases | gzip > /backup/db-$(date +%Y%m%d).sql.gz
```

### Backup struktur i S3

```
saasplatform-backups/
├── backups/                          # Velero backups
│   ├── nightly-backup-20260101030000/  # Natlig backup
│   │   ├── backup.json
│   │   ├── velero-backup.log
│   │   └── ...
│   └── tenant-backup-20260101120000/  # Manuel tenant backup
│       └── ...
├── pre-migration-backups/           # Pre-migration snapshots
│   └── tenant-12345/
│       └── pre-migration-23.0.2-20260101120000.sql.gz
└── db-dumps/                        # Natlige DB-dumps
    └── tenant-12345/
        └── 20260101-030000.sql.gz
```

## Monitoring

### Velero metrics

```bash
# Velero udsætter Prometheus metrics
kubectl get service -n velero velero-metrics

# Tilføj til Prometheus (se Infrastructure/monitoring/prometheus-values.yaml)
```

### Alerts

```yaml
# Alert for backup fejl
groups:
- name: velero
  rules:
  - alert: VeleroBackupFailed
    expr: velero_backup_failed_total > 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Velero backup fejlede"
      description: "{{ $labels.backup }} backup fejlede"

  - alert: VeleroBackupPartial
    expr: velero_backup_partial_failed_total > 0
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Velero backup delvis fejlet"
      description: "{{ $labels.backup }} backup havde delvise fejl"
```

## Fejlfinding

### Backup fejler

```bash
# Tjek Velero logs
kubectl logs -n velero deployment/velero

# Tjek backup description
velero backup describe <backup-name>

# Tjek storage
velero backup-location get
velero backup-location describe wasabi
```

### Restore fejler

```bash
# Tjek restore logs
velero restore describe <restore-name>

# Tjek for conflicts
kubectl get events -n <namespace>

# Tjek PVC status
kubectl get pvc -n <namespace>
```

### S3 adgangsproblemer

```bash
# Test S3 adgang
AWS_ACCESS_KEY_ID=$(cat Infrastructure/velero/velero-credentials | grep aws_access_key_id | cut -d= -f2 | tr -d ' ')
AWS_SECRET_ACCESS_KEY=$(cat Infrastructure/velero/velero-credentials | grep aws_secret_access_key | cut -d= -f2 | tr -d ' ')

aws s3 --endpoint-url https://s3.wasabisys.com ls s3://saasplatform-backups \
  --access-key $AWS_ACCESS_KEY_ID \
  --secret-key $AWS_SECRET_ACCESS_KEY
```

## Sikkerhed

### Encryption

```bash
# Aktiver encryption at rest
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.4.0 \
  --bucket saasplatform-backups \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=https://s3.wasabisys.com \
  --snapshot-location-config region=us-east-1 \
  --secret-file ./Infrastructure/velero/velero-credentials \
  --namespace velero \
  --use-volume-snapshots=true \
  --backup-location-config encryptionKey=<32-byte-base64-encoded-key>
```

### IAM Policy (Wasabi)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject",
        "s3:GetBucketLocation",
        "s3:PutBucketPolicy"
      ],
      "Resource": [
        "arn:aws:s3:::saasplatform-backups",
        "arn:aws:s3:::saasplatform-backups/*"
      ]
    }
  ]
}
```

## Ressourcer

- [Velero Dokumentation](https://velero.io/docs/)
- [Velero + Wasabi Guide](https://www.wasabi.com/velero-backup-kubernetes/)
- [Velero AWS Plugin](https://github.com/vmware-tanzu/velero-plugin-for-aws)
- [Wasabi S3 API](https://s3.wasabisys.com/)
