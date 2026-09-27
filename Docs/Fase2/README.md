# Fase 2 - Produktionsmiljo

## Formaal

Implementere **produktionsklar drift** af saasplatform med:
- **Canary-rollout** for stratificeret opdatering af tenants
- **Velero backup** med S3 (Wasabi) og natlig DB-dump
- **Observability stack** (Prometheus + Grafana + Loki) med dashboards og alerts
- **Produktions-miljo** for begge deployment-typer (k3s + native)

**Exit-kriterier:**
- Canary-rollout rutine fungerer (stratificeret + rotation)
- Velero + natlig DB-dump funktionel
- Dashboards og alerts funktionelle
- Produktionsmiljo for begge deployment-typer etableret

---

## Overblik

Fase 2 bygger oven pa fase 1c (livscyklus og gendannelse) og tilfoejer:
1. **Canary-rollout** for automatisk opdatering af tenants
2. **Produktions-observability** med monitoring, logging og alerting
3. **Produktions-infrastruktur** med high availability og skalering
4. **SellYourSaaS integration** med betaling, suspension og support

---

## Arkitektur Reference

Se [Arkitektur.md](../Arkitektur.md) for:
- §3.5: Opdatering af tenant-software (Canary-rollout)
- §3.5.1: Stratificeret canary (standard vs. premium)
- §3.5.2: Canary rotation (indeksbaseret)
- §3.5.3: Fejlhaandtering (rollback)
- §3.6: Observability (Prometheus, Grafana, Loki)
- §3.7: Runner placering og permissions

---

## Forudsætninger

- [ ] Fase 1c er faerdig (livscyklus og gendannelse fungerer)
- [ ] k3s cluster koerer med Traefik, cert-manager, SealedSecrets
- [ ] K8s-runner VM er opsat
- [ ] Velero er installeret i clusteret
- [ ] Wasabi S3 er konfigureret
- [ ] Helm chart (erp-tenant) er deployet
- [ ] Native deployment (fase 1a) fungerer

---

## 1. Canary-Rollout Infrastructure

### 1.1 Canary-Algoritme

Ifoelge [Arkitektur.md §3.5.1](../Arkitektur.md#351-stratificeret-canary):

**Stratificeret canary:**
- Standard plan: 5% canary
- Premium plan: 10% canary
- Canary window: 30 minutter (1800 sekunder)

**Canary rotation:**
- Rotationsindeks gemmes i fil: `/var/lib/saasplatform/canary-index-{strata}-{server}.txt`
- Indeks inkrementeres for hver canary-iteration
- Tenants vaelges baseret paa rotationsindeks mod total tenants

### 1.2 Canary-rollout Script

Se [Scripts/canary-rollout.sh](../../Scripts/canary-rollout.sh) for:
- Canary-algoritme implementation
- Stratificeret udvaelgelse (standard vs. premium)
- Rotationsindeks haandtering
- Fejlhaandtering og rollback

**Miljoevariabler:**
```bash
# I /etc/saasplatform/config
CANARY_PERCENTAGE=5          # 5% canary for standard
CANARY_PERCENTAGE_PREMIUM=10 # 10% canary for premium
CANARY_WINDOW=1800           # 30 minutter
```

### 1.3 Opret Rotationsindeks Filer

```bash
# Paa runner VM
sudo mkdir -p /var/lib/saasplatform

# Opret for standard plan (k8s-prod server)
touch /var/lib/saasplatform/canary-index-standard-k8s-prod.txt
echo 0 > /var/lib/saasplatform/canary-index-standard-k8s-prod.txt

# Opret for premium plan (k8s-prod server)
touch /var/lib/saasplatform/canary-index-premium-k8s-prod.txt
echo 0 > /var/lib/saasplatform/canary-index-premium-k8s-prod.txt

# Opret for native deployment (native-prod server)
touch /var/lib/saasplatform/canary-index-standard-native-prod.txt
echo 0 > /var/lib/saasplatform/canary-index-standard-native-prod.txt
touch /var/lib/saasplatform/canary-index-premium-native-prod.txt
echo 0 > /var/lib/saasplatform/canary-index-premium-native-prod.txt

# Saet permissions
sudo chown -R saasplatform:saasplatform /var/lib/saasplatform
```

---

## 2. Observability Stack

### 2.1 Prometheus

**Formaal:** Metrikker for cluster, tenants og applikationer

**Installation:**
```bash
# Tilfoej repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Installer kube-prometheus-stack
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 58.0.0 \
  -f Infrastructure/monitoring/prometheus-values.yaml
```

**Konfiguration (prometheus-values.yaml):**
```yaml
prometheus:
  server:
    resources:
      requests:
        cpu: 1000m
        memory: 4Gi
      limits:
        cpu: 2000m
        memory: 8Gi
    retention: 30d
    retentionSize: "50GiB"

grafana:
  enabled: false  # Separate Grafana installation

alertmanager:
  enabled: true
  config:
    route:
      receiver: 'slack-notifications'
    receivers:
      - name: 'slack-notifications'
        slack_configs:
          - api_url: 'https://hooks.slack.com/services/...'
            channel: '#saasplatform-alerts'
```

### 2.2 Grafana

**Formaal:** Dashboards for visualisering af metrikker

**Installation:**
```bash
# Tilfoej repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Installer Grafana
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --version 7.3.0 \
  -f Infrastructure/monitoring/grafana-values.yaml
```

**Konfiguration (grafana-values.yaml):**
```yaml
replicaCount: 1

persistence:
  enabled: true
  size: 10Gi

adminPassword: "<secure-password>"

sidecar:
  dashboards:
    enabled: true
    searchNamespace: ALL
  datasources:
    enabled: true
    label: "grafana_datasource"

# Mount custom dashboards
dashboardsConfigMaps:
  - configMapName: saasplatform-dashboards
    fileName: saasplatform-dashboard.json
```

**Dashboards:**
- Cluster overview (CPU, memory, pods)
- Tenant overview (per-tenant metrics)
- Database metrics (MariaDB)
- Application metrics (Dolibarr)
- Canary-rollout status

### 2.3 Loki

**Formaal:** Centraliseret logging

**Installation:**
```bash
# Tilfoej repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Installer Loki
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --version 5.41.0 \
  -f Infrastructure/monitoring/loki-values.yaml

# Installer Promtail
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --version 6.15.0 \
  -f Infrastructure/monitoring/promtail-values.yaml
```

**Konfiguration (loki-values.yaml):**
```yaml
loki:
  resources:
    requests:
      cpu: 1000m
      memory: 4Gi
    limits:
      cpu: 2000m
      memory: 8Gi
  persistence:
    enabled: true
    size: 50Gi

singleBinary:
  replicas: 1
```

### 2.4 Alerts

**Kritiske alerts:**
- Tenant nedetid (healthz check failed)
- Database nedetid (MariaDB pod not ready)
- High CPU usage (>80% for 5 min)
- High memory usage (>90% for 5 min)
- Disk space low (<10% free)
- Certificate expiration (<7 days)
- Backup failure

**Alert rules (prometheus-rules.yaml):**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: saasplatform-alerts
  namespace: monitoring
spec:
  groups:
    - name: tenant.rules
      rules:
        - alert: TenantDown
          expr: up{namespace=~"tenant-.*"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Tenant {{ $labels.namespace }} is down"
            description: "Healthz check failed for tenant {{ $labels.namespace }}"

        - alert: HighCPUUsage
          expr: (sum(rate(container_cpu_usage_seconds_total{namespace=~"tenant-.*"}[5m])) by (namespace) / sum(container_spec_cpu_quota{namespace=~"tenant-.*"} / container_spec_cpu_period{namespace=~"tenant-.*"}) by (namespace)) * 100 > 80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High CPU usage in tenant {{ $labels.namespace }}"
            description: "CPU usage is {{ $value }}% for tenant {{ $labels.namespace }}"
```

---

## 3. Velero Backup (Produktion)

### 3.1 Wasabi S3 Konfiguration

**Bucket struktur:**
```
saasplatform-backups/
  daily/
    {date}/tenant-{instance}/
      backup-{timestamp}.tar.gz
      metadata.json
  weekly/
    {week}/tenant-{instance}/
      backup-{timestamp}.tar.gz
  monthly/
    {month}/tenant-{instance}/
      backup-{timestamp}.tar.gz
  pre-migration/
    tenant-{instance}/
      pre-migration-{version}-{timestamp}.sql.gz
```

**Retention policies:**
- Daily: 7 dage (standard), 30 dage (premium)
- Weekly: 4 uger
- Monthly: 12 maneder
- Pre-migration: 30 dage

### 3.2 Velero Installation (Produktion)

```bash
# Installer Velero CLI
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xvf velero-v1.12.0-linux-amd64.tar.gz
sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/

# Opret credentials fil (Wasabi)
mkdir -p Infrastructure/velero
cat > Infrastructure/velero/wasabi-credentials << 'EOF'
[default]
aws_access_key_id = <WASABI_ACCESS_KEY>
aws_secret_access_key = <WASABI_SECRET_KEY>
EOF

# Installer Velero
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.4.0 \
  --bucket saasplatform-backups \
  --backup-location-config region=eu-central-1,s3ForcePathStyle=true,s3Url=https://s3.eu-central-1.wasabisys.com \
  --snapshot-location-config region=eu-central-1 \
  --secret-file ./Infrastructure/velero/wasabi-credentials \
  --namespace velero \
  --wait
```

### 3.3 Backup Schedules

**Natlig backup (alle tenants):**
```yaml
# Infrastructure/velero/daily-backup.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: velero
spec:
  schedule: "0 3 * * *"  # Kl. 03:00 hver nat
  template:
    ttl: 168h  # 7 dage
    includedNamespaces:
      - tenant-*
    excludedResources:
      - pods
      - events
```

**Ugentlig backup (standard tenants):**
```yaml
# Infrastructure/velero/weekly-backup-standard.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: weekly-backup-standard
  namespace: velero
spec:
  schedule: "0 4 * * 0"  # Kl. 04:00 hver sondag
  template:
    ttl: 672h  # 28 dage (4 uger)
    includedNamespaces:
      - tenant-*
    labelSelector:
      matchLabels:
        saasplatform.dk/plan: standard
```

**Maenedlig backup (premium tenants):**
```yaml
# Infrastructure/velero/monthly-backup-premium.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: monthly-backup-premium
  namespace: velero
spec:
  schedule: "0 5 1 * *"  # Kl. 05:00 den 1. i hver maned
  template:
    ttl: 8760h  # 365 dage (12 maneder)
    includedNamespaces:
      - tenant-*
    labelSelector:
      matchLabels:
        saasplatform.dk/plan: premium
```

### 3.4 Natlig DB-dump

**CronJob i Helm chart:**
```yaml
# I values.yaml for erp-tenant chart
backup:
  enabled: true
  daily:
    enabled: true
    schedule: "0 2 * * *"  # Kl. 02:00
    s3Enabled: true
    bucket: "saasplatform-backups/daily"
    retentionDays: 7  # standard
    # retentionDays: 30  # premium
```

---

## 4. Produktionsmiljo Setup

### 4.1 k3s Cluster (Produktion)

**Hardware krav:**
| Komponent | Minimum | Anbefalet | Noter |
|-----------|---------|-----------|-------|
| k3s Master | 4 vCPUs, 8GB RAM, 100GB disk | 8 vCPUs, 16GB RAM, 200GB disk | Inkluderer etcd |
| k3s Worker | 4 vCPUs, 8GB RAM, 100GB disk | 8 vCPUs, 16GB RAM, 200GB disk | Per 20 tenants |
| Runner VM | 2 vCPUs, 4GB RAM, 50GB disk | 4 vCPUs, 8GB RAM, 100GB disk | Uden for clusteret |

**k3s installation:**
```bash
# Paa master node
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \  # Vi bruger vores egen Traefik installation
  --disable servicelb \
  --cluster-init

# Paa worker nodes
curl -sfL https://get.k3s.io | K3S_URL=https://<master-ip>:6443 K3S_TOKEN=<token> sh -s - agent
```

**Traefik installation:**
```bash
# Installer Traefik via Helm
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --version 25.0.0 \
  -f Infrastructure/traefik/values.yaml
```

### 4.2 DNS Konfiguration (Cloudflare)

**Records:**
| Type | Name | Content | TTL | Proxy |
|------|------|---------|-----|-------|
| A | @ | <k3s-master-ip> | 300 | No |
| A | *.kunder.saasplatform.dk | <traefik-lb-ip> | 300 | No |
| CNAME | www | saasplatform.dk | 300 | No |
| A | runner | <runner-ip> | 300 | No |

### 4.3 SellYourSaaS Integration

**Deployment Servers:**
- `k8s-prod`: k3s cluster (Dolibarr ERP)
- `native-prod`: Native server (PIM)

**Packages:**
- `kubernetes-dolibarr`: Helm chart for Dolibarr ERP
- `native-pim`: Native deployment for PIM

**Plans:**
- `standard`: CPU 1, Memory 2GB, Storage 5GB, Backup 7 dage
- `premium`: CPU 2, Memory 4GB, Storage 20GB, Backup 30 dage

---

## 5. Drift og Vedligeholdelse

### 5.1 Daglig Drift

**Backup verification:**
```bash
# Tjek Velero backups
velero backup get --sort-by=.status.completionTimestamp --reverse

# Tjek seneste backup
velero backup get <latest-backup> -o yaml

# Tjek backup logs
velero backup logs <backup-name>
```

**Monitoring:**
```bash
# Tjek Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
sleep 2
curl http://localhost:9090/targets

# Tjek aktive alerts
curl http://localhost:9090/api/v1/alerts
```

**Certificate fornyelse:**
```bash
# Tjek certifikater
kubectl get certificate -A

# Tjek fornyelse status
kubectl describe certificate -n tenant-12345

# Tjek ClusterIssuer
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod
```

### 5.2 Ugentlig Drift

**Test restore:**
```bash
# Vaelig en tilfaeldig tenant
TENANT=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-' | shuf -n 1)

# Tag backup
velero backup create weekly-test-backup --include-namespaces $TENANT

# Vent paa backup
velero backup get weekly-test-backup --wait

# Slet tenant
./Scripts/undeploy.sh "${TENANT#tenant-}"

# Restore tenant
velero restore create --from-backup weekly-test-backup

# Verificer
./Scripts/cron.sh "${TENANT#tenant-}"
```

### 5.3 Maenedlig Drift

**Canary-rollout test:**
```bash
# Koer canary-rollout med ny version
export SELLYOURSAAS_VERSION="23.0.3"
export CANARY_PERCENTAGE=1  # 1% for test
./Scripts/canary-rollout.sh

# Vent paa canary window
sleep 1800

# Tjek canary status
kubectl get pods -n tenant-* -l app=dolibarr,canary=true

# Verificer healthz for canary tenants
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  contract=${ns#tenant-}
  curl -fsS -o /dev/null -m 5 "https://${contract}.kunder.saasplatform.dk/healthz"
done
```

**k3s opgradering:**
```bash
# Tjek nuværende version
kubectl get nodes -o wide

# Opgrader k3s (se Infrastructure/k3s/README.md)
# 1. Backup etcd
# 2. Opgrader master
# 3. Opgrader workers
# 4. Verificer
```

### 5.4 Kvartalsvis Drift

**Full backup test:**
```bash
# Tag full backup af alle tenants
velero backup create quarterly-full-backup --include-namespaces tenant-*

# Vent paa backup
velero backup get quarterly-full-backup --wait

# Test restore af et udvalg af tenants
velero restore create --from-backup quarterly-full-backup \
  --include-namespaces tenant-test1,tenant-test2
```

**Sikkerhedsrevision:**
- Rotere alle credentials (S3, database, etc.)
- Opdatere certifikater
- Tjek RBAC permissions
- Audit logs

---

## 6. Skalering

### 6.1 Horisontal Skalering

**Tilfoej k3s worker node:**
```bash
# Paa ny worker node
curl -sfL https://get.k3s.io | K3S_URL=https://k3s-master.saasplatform.dk:6443 K3S_TOKEN=<token> sh -s - agent

# Verificer
kubectl get nodes
```

**Skaler Velero:**
```bash
kubectl scale deployment velero -n velero --replicas=2
```

**Skaler Monitoring:**
```bash
# Prometheus
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.server.replicaCount=2

# Grafana
helm upgrade grafana grafana/grafana \
  --namespace monitoring \
  --set replicaCount=2

# Loki
helm upgrade loki grafana/loki \
  --namespace monitoring \
  --set loki.replicaCount=2
```

### 6.2 Vertikal Skalering

**Prometheus:**
```yaml
# Infrastructure/monitoring/prometheus-values.yaml
prometheus:
  server:
    resources:
      requests:
        cpu: 4000m
        memory: 16Gi
      limits:
        cpu: 8000m
        memory: 32Gi
```

**Loki:**
```yaml
# Infrastructure/monitoring/loki-values.yaml
loki:
  resources:
    requests:
      cpu: 4000m
      memory: 16Gi
    limits:
      cpu: 8000m
      memory: 32Gi
```

---

## 7. Sikkerhed

### 7.1 k3s Sikkerhed

- **API adgang**: Kun tillad fra runner VM og admin IPs
- **Firewall**: Aktiver UFW (se [Infrastructure/k3s/README.md](../Infrastructure/k3s/README.md#sikkerhed))
- **RBAC**: Minimal permissions til service accounts
- **Network Policies**: Default deny, selective egress

### 7.2 Backup Sikkerhed

- **S3 credentials**: Gemt i sealed-secrets
- **Encryption**: Aktiver Velero encryption at rest
- **Retention**: Konfigurer retention policies
- **Access logging**: Aktiver S3 access logs

### 7.3 Monitoring Sikkerhed

- **Authentication**: Grafana basic auth + OAuth
- **RBAC**: Grafana team/role permissions
- **Network policies**: Restriktioner paa monitoring namespace
- **Data retention**: Konfigurer log retention

### 7.4 Secrets Management

- **SealedSecrets**: Alle secrets gemt som SealedSecrets
- **kubeseal cert**: Gemt sikkert paa runner VM
- **S3 credentials**: Gemt i sealed-secrets
- **Database credentials**: Genereret per-tenant, gemt som SealedSecrets

---

## 8. Fejlfinding

### 8.1 Canary-rollout Fejl

```bash
# Tjek rotationsindeks
cat /var/lib/saasplatform/canary-index-*.txt

# Tjek canary-rollout logs
journalctl -u saasplatform-k8s -f

# Tjek tenant status
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  echo "Namespace: $ns"
  kubectl get pods -n $ns
  kubectl get helmrelease -n $ns
done

# Tjek canary labels
kubectl get pods -A -l canary=true
```

### 8.2 Velero Fejl

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

# Tjek S3 adgang
AWS_ACCESS_KEY_ID=$(cat /etc/saasplatform/velero-credentials | grep aws_access_key_id | cut -d= -f2 | tr -d ' ')
AWS_SECRET_ACCESS_KEY=$(cat /etc/saasplatform/velero-credentials | grep aws_secret_access_key | cut -d= -f2 | tr -d ' ')
aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com ls s3://saasplatform-backups --recursive
```

### 8.3 Monitoring Fejl

```bash
# Tjek Prometheus
kubectl logs -n monitoring deployment/prometheus-kube-prometheus-prometheus

# Tjek Grafana
kubectl logs -n monitoring deployment/grafana

# Tjek Loki
kubectl logs -n monitoring deployment/loki

# Tjek Promtail
kubectl logs -n monitoring daemonset/promtail

# Tjek metrics
kubectl get --raw /metrics
```

### 8.4 Tenant Fejl

```bash
# Tjek tenant pods
kubectl get pods -n tenant-12345

# Tjek pod logs
kubectl logs -n tenant-12345 <pod-name>

# Tjek events
kubectl get events -n tenant-12345

# Tjek healthz
curl -v https://12345.kunder.saasplatform.dk/healthz

# Tjek database
kubectl exec -n tenant-12345 pod/mariadb-0 -- mysql -u root -p -e "SHOW DATABASES;"
```

---

## 9. Nedetid Procedurer

### 9.1 k3s Cluster Nedetid

1. **Identificer problem**: `kubectl get nodes`
2. **Genstart k3s**: `sudo systemctl restart k3s`
3. **Hvis k3s ikke starter**: Tjek logs `sudo journalctl -u k3s -f`
4. **Hvis etcd korrupt**: Restore fra backup

### 9.2 Tenant Nedetid

1. **Tjek tenant status**: `kubectl get pods -n tenant-12345`
2. **Tjek logs**: `kubectl logs -n tenant-12345 <pod>`
3. **Restart pod**: `kubectl delete pod -n tenant-12345 <pod>`
4. **Hvis fortsat problemer**: Restore fra backup

### 9.3 Backup Nedetid

1. **Tjek Velero**: `kubectl get pods -n velero`
2. **Restart Velero**: `kubectl rollout restart deployment velero -n velero`
3. **Tjek S3**: `aws s3 ls s3://saasplatform-backups`
4. **Hvis S3 nede**: Vent paa S3, genkoer backup

### 9.4 Monitoring Nedetid

1. **Tjek Prometheus**: `kubectl get pods -n monitoring -l app=prometheus`
2. **Restart Prometheus**: `kubectl rollout restart deployment prometheus-kube-prometheus-prometheus -n monitoring`
3. **Tjek Grafana**: `kubectl get pods -n monitoring -l app=grafana`
4. **Restart Grafana**: `kubectl rollout restart deployment grafana -n monitoring`

---

## 10. Ressourcer

- [Arkitektur Dokumentation](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
- [Infrastructure: k3s](../Infrastructure/k3s/README.md)
- [Infrastructure: Velero](../Infrastructure/velero/README.md)
- [Infrastructure: Monitoring](../Infrastructure/monitoring/README.md)
- [k3s Dokumentation](https://docs.k3s.io/)
- [Velero Dokumentation](https://velero.io/docs/)
- [Prometheus Dokumentation](https://prometheus.io/docs/)
- [Grafana Dokumentation](https://grafana.com/docs/)
- [Loki Dokumentation](https://grafana.com/docs/loki/latest/)
- [Cloudflare API](https://api.cloudflare.com/)
- [Wasabi S3 API](https://s3.wasabisys.com/)
- [SellYourSaaS Dokumentation](https://github.com/DoliCloud/sellyoursaas)

---

## 11. Relaterede Scripts

| Script | Beskrivelse |
|--------|-------------|
| `canary-rollout.sh` | Haandterer canary-rollout for tenants |
| `canary-check.sh` | Tjekker healthz for canary tenants |
| `canary-rollout.sh` | Ruller canary ud til naeste batch |
| `migrate.sh` | Haandterer migrering af tenant-software |
| `rollback.sh` | Udfoerer rollback til tidligere version |
| `restore-tenant.sh` | Restorer tenant fra backup |

---

## 12. Relaterede Dokumentation

- [Fase 1a: Native Deployment](../Fase1a/README.md) - Native deployment guide
- [Fase 1b: K8s Grundintegration](../Fase1b/README.md) - Kubernetes integration
- [Fase 1c: Livscyklus og Gendannelse](../Fase1c/README.md) - Backup, restore, rollback
- [Fase 2: Produktions-opsaetningsguide](Produktions-opsætningsguide.md) - Detaljeret opsaetningsguide
- [Arkitektur.md](../Arkitektur.md) - System arkitektur
- [DECISIONS.md](../DECISIONS.md) - Decision log
