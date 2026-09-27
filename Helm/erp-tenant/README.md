# erp-tenant Helm Chart

Per-tenant Dolibarr ERP deployment for saasplatform.

## Features

- **Dolibarr Deployment** with healthz endpoint
- **MariaDB StatefulSet** with PVC per tenant
- **Ingress** with Traefik and cert-manager TLS
- **NetworkPolicy** with default-deny + selective egress
- **ResourceQuota** per tenant
- **Suspension support** (replicas=0, suspended-page, CronJobs removed)
- **SealedSecrets** for DB credentials
- **Backup CronJob** with S3 support
- **Pre-migration snapshot** support
- **Rollback** support

## Requirements

- Kubernetes >= 1.24
- Helm >= 3.0
- cert-manager installed in cluster
- SealedSecrets controller installed
- Traefik or other ingress controller

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `instance` | string | `""` | Tenant instance identifier |
| `domain` | string | `""` | Tenant domain (e.g., tenant-123.example.com) |
| `suspended` | bool | `false` | Whether tenant is suspended |
| `image.repository` | string | `"ghcr.io/smoeberg/dolibarr"` | Dolibarr image repository |
| `image.tag` | string | `"23.0.1"` | Dolibarr image tag |
| `image.previousTag` | string | `""` | Previous version for rollback |
| `dolibarr.resources` | object | `{requests: {cpu: 100m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}` | Dolibarr resource requests/limits |
| `dolibarr.migration.enabled` | bool | `false` | Enable migration mode |
| `dolibarr.replicaCount` | int | `1` | Number of replicas (NOTE: currently limited to 1 due to ReadWriteOnce PVC) |
| `dolibarr.migration.preMigrationSnapshot` | string | `""` | Pre-migration snapshot name |
| `db.enabled` | bool | `true` | Enable MariaDB |
| `db.storage` | string | `"5Gi"` | MariaDB storage size |
| `db.storageClass` | string | `""` | MariaDB storage class |
| `db.resources` | object | `{requests: {cpu: 100m, memory: 512Mi}, limits: {cpu: "1", memory: 1Gi}}` | MariaDB resources |
| `ingress.enabled` | bool | `true` | Enable Ingress |
| `ingress.className` | string | `"traefik"` | Ingress class |
| `ingress.tls` | bool | `true` | Enable TLS |
| `backup.enabled` | bool | `true` | Enable backup CronJob |
| `backup.schedule` | string | `"0 3 * * *"` | Backup schedule |
| `backup.retentionDays` | int | `7` | Backup retention days |
| `backup.s3Enabled` | bool | `false` | Enable S3 upload |
| `backup.bucket` | string | `""` | S3 bucket name |
| `backup.preMigration.enabled` | bool | `true` | Enable pre-migration snapshots |
| `backup.preMigration.bucket` | string | `"pre-migration-backups"` | Pre-migration S3 bucket |
| `quota.requestsCpu` | string | `"1"` | CPU requests quota |
| `quota.requestsMemory` | string | `"2Gi"` | Memory requests quota |
| `quota.limitsCpu` | string | `"2"` | CPU limits quota |
| `quota.limitsMemory` | string | `"4Gi"` | Memory limits quota |
| `quota.pvc` | string | `"3"` | PVC quota |
| `networkPolicy.defaultDeny` | bool | `true` | Enable default deny NetworkPolicy |
| `networkPolicy.egressMail` | bool | `true` | Allow mail egress |
| `rollback.enabled` | bool | `false` | Enable rollback mode |
| `rollback.targetVersion` | string | `""` | Target version for rollback |
| `rollback.restoreFromSnapshot` | string | `""` | Snapshot to restore from |

## Usage

```bash
# Deploy tenant
helm upgrade --install tenant-123 ./erp-tenant \
  --namespace tenant-123 --create-namespace \
  -f values-tenant-123.yaml \
  --set domain=tenant-123.example.com \
  --set instance=123

# Suspend tenant
helm upgrade tenant-123 ./erp-tenant \
  --namespace tenant-123 \
  --reuse-values \
  --set suspended=true

# Unsuspend tenant
helm upgrade tenant-123 ./erp-tenant \
  --namespace tenant-123 \
  --reuse-values \
  --set suspended=false
```

## Limitations

### Replica Count
**Important:** The `replicaCount` value is currently **limited to 1** due to the documents PVC using `ReadWriteOnce` access mode. 
Setting `replicaCount > 1` will result in pods being unable to schedule (or only scheduling on the same node, depending on CSI driver).

To enable horizontal scaling in the future:
1. Change documents PVC to use `ReadWriteMany` access mode (requires compatible storage backend)
2. Or implement shared storage solution (NFS, CephFS, etc.)

Until then, `replicaCount` should remain at 1.

### Storage
- Each tenant gets its own MariaDB StatefulSet with dedicated PVC
- Documents PVC is ReadWriteOnce (single pod access)
- Backup PVCs use emptyDir with size limits

### Security
- All secrets are managed via SealedSecrets
- NetworkPolicy defaults to deny-all with selective egress
- ResourceQuota enforced per tenant namespace
