# Fase 2 - Produktions-opsætningsguide

## Introduktion

Denne guide beskriver hvordan man opsætter saasplatform i produktion. Guiden følger strukturen fra [Arkitektur.md](../Arkitektur.md) og dækker alle komponenter nødvendige for fase 2.

## Forudsætninger

### Hardware krav

| Komponent | Minimum | Anbefalet | Noter |
|-----------|---------|-----------|-------|
| k3s Master | 2 vCPUs, 4GB RAM, 50GB disk | 4 vCPUs, 8GB RAM, 100GB disk | Inkluderer etcd |
| k3s Worker | 2 vCPUs, 4GB RAM, 50GB disk | 4 vCPUs, 8GB RAM, 100GB disk | Per 20 tenants |
| Runner VM | 2 vCPUs, 2GB RAM, 20GB disk | 2 vCPUs, 2GB RAM, 20GB disk | Uden for clusteret |
| Database | - | - | MariaDB i tenant namespace |

### Software krav

- **OS**: Ubuntu 22.04 LTS (alle servere)
- **Kubernetes**: k3s v1.31+
- **Container Runtime**: containerd (inkluderet i k3s)
- **DNS**: Cloudflare (eller anden API-drevet provider)
- **Storage**: Wasabi S3 (eller anden S3-kompatibel)
- **Monitoring**: Prometheus, Grafana, Loki

### Netværk

- **k3s API**: Port 6443 (kun tillad fra runner VM og admin IPs)
- **Traefik HTTP**: Port 80
- **Traefik HTTPS**: Port 443
- **S3**: Port 443 (Wasabi)
- **SSH**: Port 22 (alle servere)

## Step 1: Infrastruktur Setup

### 1.1 Opret servere

#### k3s Master Server

```bash
# SSH til serveren
ssh root@k3s-master.saasplatform.dk

# Følg opsætningsguiden
# Se: Infrastructure/k3s/README.md
```

#### k3s Worker Nodes (valgfrit)

```bash
# SSH til worker node
ssh root@k3s-worker-1.saasplatform.dk

# Installer k3s agent
curl -sfL https://get.k3s.io | K3S_URL=https://k3s-master.saasplatform.dk:6443 K3S_TOKEN=<token> sh -s - agent

# Verificer
kubectl get nodes
```

#### Runner VM

```bash
# SSH til runner
ssh saasplatform@runner.saasplatform.dk

# Følg opsætningsguiden for runner
# Se: Infrastructure/k3s/README.md (afsnit "k3s Runner VM")
```

### 1.2 Konfigurer DNS (Cloudflare)

```bash
# Opret A-record for k3s master
# IP: <k3s-master-ip>
# Type: A
# Name: @
# TTL: 300

# Opret wildcard record for tenants
# Type: A
# Name: *.kunder.saasplatform.dk
# Content: <traefik-loadbalancer-ip>
# TTL: 300
```

### 1.3 Konfigurer S3 (Wasabi)

1. Opret Wasabi konto
2. Opret bucket: `saasplatform-backups`
3. Opret access key og secret key
4. Gem credentials sikkert (se sikkerhedsafsnit)

## Step 2: k3s Cluster Setup

Følg [Infrastructure/k3s/README.md](../Infrastructure/k3s/README.md) for at opsætte:

1. **k3s cluster** med Traefik
2. **cert-manager** med Cloudflare DNS-01
3. **sealed-secrets** controller
4. **metrics-server**
5. **StorageClass** (local-path)

### Verificering

```bash
# Tjek cluster status
kubectl get nodes

# Tjek system pods
kubectl get pods -A

# Tjek cert-manager
kubectl get pods -n cert-manager

# Tjek sealed-secrets
kubectl get pods -n kube-system | grep sealed-secrets
```

## Step 3: Velero Backup Setup

Følg [Infrastructure/velero/README.md](../Infrastructure/velero/README.md) for at opsætte:

1. **Velero controller**
2. **BackupStorageLocation** (Wasabi S3)
3. **VolumeSnapshotLocation**
4. **Natlig backup schedule**

### Verificering

```bash
# Tjek Velero pods
kubectl get pods -n velero

# Tjek backup storage
velero backup-location get

# Test backup
velero backup create test-backup --include-namespaces tenant-test1
velero backup get test-backup
```

## Step 4: Observability Stack Setup

Følg [Infrastructure/monitoring/README.md](../Infrastructure/monitoring/README.md) for at opsætte:

1. **Prometheus**
2. **Grafana**
3. **Loki**
4. **Promtail**
5. **Dashboards**
6. **Alerts**

### Verificering

```bash
# Tjek monitoring pods
kubectl get pods -n monitoring

# Port-forward til Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# Adgang: http://localhost:3000
# Login: admin / <password>
```

## Step 5: Deploy Første Tenant

### 5.1 Opret package i SellYourSaaS

1. Gå til SellYourSaaS admin
2. Naviger til "Deployment Servers & Packages"
3. Opret ny package:
   - **Name**: kubernetes-dolibarr
   - **Type**: kubernetes
   - **Version**: 1
   - **Actions**: Se [Packages/kubernetes-dolibarr.yaml](../Packages/kubernetes-dolibarr.yaml)

### 5.2 Konfigurer deployment server

1. Gå til "Deployment Servers"
2. Opret ny server:
   - **Name**: k8s-prod
   - **Hostname**: runner.saasplatform.dk
   - **Port**: 8080
   - **Type**: kubernetes
   - **Packages**: kubernetes-dolibarr

### 5.3 Test deploy

```bash
# På runner VM
cd /opt/saasplatform

# Test deploy script
export SELLYOURSAAS_INSTANCE_NAME="test1"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://test1.kunder.saasplatform.dk"
export SELLYOURSAAS_VERSION="23.0.1"

./Scripts/deploy.sh test1
```

### Verificering

```bash
# Tjek tenant namespace
kubectl get ns tenant-test1

# Tjek pods
kubectl get pods -n tenant-test1

# Tjek ingress
kubectl get ingress -n tenant-test1

# Tjek healthz
curl -fsS -o /dev/null -m 5 "https://test1.kunder.saasplatform.dk/healthz"
```

## Step 6: Konfigurer Canary-rollout

### 6.1 Opret rotationsindeks filer

```bash
# På runner VM
sudo mkdir -p /var/lib/saasplatform

# Opret for standard plan
for server in k8s-prod; do
  touch /var/lib/saasplatform/canary-index-standard-${server}.txt
  echo 0 > /var/lib/saasplatform/canary-index-standard-${server}.txt
done

# Opret for premium plan
for server in k8s-prod; do
  touch /var/lib/saasplatform/canary-index-premium-${server}.txt
  echo 0 > /var/lib/saasplatform/canary-index-premium-${server}.txt
done

# Sæt permissions
sudo chown -R saasplatform:saasplatform /var/lib/saasplatform
```

### 6.2 Konfigurer miljøvariabler

```bash
# Rediger /etc/saasplatform/config
cat <<EOF | sudo tee -a /etc/saasplatform/config
# Canary settings
CANARY_PERCENTAGE=5
CANARY_WINDOW=1800
EOF
```

### 6.3 Test canary-rollout

```bash
# Deploy 10 test tenants
for i in $(seq 1 10); do
  export SELLYOURSAAS_INSTANCE_NAME="canary-test-${i}"
  export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://canary-test-${i}.kunder.saasplatform.dk"
  export SELLYOURSAAS_VERSION="23.0.1"
  ./Scripts/deploy.sh "canary-test-${i}"
done

# Vent på alle tenants er klar
sleep 60

# Kør canary-rollout
export SELLYOURSAAS_VERSION="23.0.2"
export CANARY_PERCENTAGE=10  # 10% af 10 = 1 tenant
./Scripts/canary-rollout.sh
```

## Step 7: Konfigurer SellYourSaaS

### 7.1 Konfigurer Stripe/SEPA

1. Gå til SellYourSaaS admin
2. Naviger til "Payment Gateways"
3. Konfigurer Stripe:
   - **API Key**: <stripe-secret-key>
   - **Publishable Key**: <stripe-publishable-key>
   - **Webhook URL**: https://saasplatform.dk/stripe-webhook

### 7.2 Konfigurer suspension

1. Gå til "Suspension Settings"
2. Konfigurer:
   - **Grace Period**: 7 dage
   - **Suspension Action**: suspend
   - **Unsuspension Action**: unsuspend
   - **Termination Action**: undeploy

### 7.3 Konfigurer plans

1. Gå til "Plans"
2. Opret plans:
   - **Standard**: CPU 1, Memory 2GB, Storage 5GB, Backup 7 dage
   - **Premium**: CPU 2, Memory 4GB, Storage 20GB, Backup 30 dage

## Step 8: Gå live

### 8.1 Test med rigtige kunder

1. Opret testkunde i SellYourSaaS
2. Tilknytt standard plan
3. Verificer at tenant deployes automatisk
4. Test betaling (Stripe test kort)
5. Test suspension (afvis betaling)
6. Test unsuspension (godkend betaling)

### 8.2 Overvågning

1. Tjek Grafana dashboards
2. Tjek alerts
3. Tjek logs i Loki
4. Tjek backup status

### 8.3 Dokumentation

- [Arkitektur.md](../Arkitektur.md) - System arkitektur
- [Fase 1a Installationstjekliste.md](../Fase%201a%20Installationstjekliste.md) - Fase 1a
- [Fase 1c Testplan.md](../Fase2/Fase%201c%20Testplan.md) - Fase 1c tests
- [Fase 2 README.md](README.md) - Fase 2 oversigt

## Drift

### Daglig drift

#### Backup verification

```bash
# Tjek Velero backups
velero backup get

# Tjek seneste backup
velero backup get --sort-by=.status.completionTimestamp --reverse | head -1

# Tjek backup logs
velero backup logs <backup-name>
```

#### Monitoring

```bash
# Tjek Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
sleep 2
curl http://localhost:9090/targets

# Tjek alerts
curl http://localhost:9090/api/v1/alerts
```

### Ugentlig drift

#### Certifikat fornyelse

```bash
# Tjek certifikater
kubectl get certificate -A

# Tjek fornyelse status
kubectl describe certificate -n tenant-12345
```

#### k3s opgradering

```bash
# Tjek nuværende version
kubectl get nodes -o wide

# Opgrader (se Infrastructure/k3s/README.md)
```

### Månedlig drift

#### Backup test

```bash
# Vælg en tilfældig tenant
TENANT=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-' | shuf -n 1)

# Tag backup
velero backup create monthly-test-backup --include-namespaces $TENANT

# Slet tenant
./Scripts/undeploy.sh "${TENANT#tenant-}"

# Restore tenant
velero restore create --from-backup monthly-test-backup

# Verificer
./Scripts/cron.sh "${TENANT#tenant-}"
```

#### Canary-rollout test

```bash
# Kør canary-rollout med ny version
export SELLYOURSAAS_VERSION="23.0.3"
export CANARY_PERCENTAGE=1
./Scripts/canary-rollout.sh
```

## Fejlfinding

### Tenant deploy fejler

```bash
# Tjek deploy logs
journalctl -u saasplatform-k8s -f

# Tjek tenant namespace
kubectl get ns tenant-12345

# Tjek pods
kubectl get pods -n tenant-12345

# Tjek pod logs
kubectl logs -n tenant-12345 <pod-name>

# Tjek events
kubectl get events -n tenant-12345
```

### Backup fejler

```bash
# Tjek Velero logs
kubectl logs -n velero deployment/velero

# Tjek backup description
velero backup describe <backup-name>

# Tjek S3 adgang
AWS_ACCESS_KEY_ID=$(cat /etc/saasplatform/velero-credentials | grep aws_access_key_id | cut -d= -f2 | tr -d ' ')
AWS_SECRET_ACCESS_KEY=$(cat /etc/saasplatform/velero-credentials | grep aws_secret_access_key | cut -d= -f2 | tr -d ' ')

aws s3 --endpoint-url https://s3.wasabisys.com ls s3://saasplatform-backups \
  --access-key $AWS_ACCESS_KEY_ID \
  --secret-key $AWS_SECRET_ACCESS_KEY
```

### cert-manager fejler

```bash
# Tjek cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Tjek ClusterIssuer
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod

# Tjek Certificate
kubectl get certificate -n tenant-12345
kubectl describe certificate -n tenant-12345
```

### Monitoring fejler

```bash
# Tjek Prometheus
kubectl logs -n monitoring deployment/prometheus-kube-prometheus-prometheus

# Tjek Grafana
kubectl logs -n monitoring deployment/grafana

# Tjek Loki
kubectl logs -n monitoring deployment/loki

# Tjek Promtail
kubectl logs -n monitoring daemonset/promtail
```

## Skalering

### Horisontal skalering

#### Tilføj k3s worker node

```bash
# På ny worker node
curl -sfL https://get.k3s.io | K3S_URL=https://k3s-master.saasplatform.dk:6443 K3S_TOKEN=<token> sh -s - agent

# Verificer
kubectl get nodes
```

#### Skaler Velero

```bash
kubectl scale deployment velero -n velero --replicas=2
```

#### Skaler monitoring

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

### Vertikal skalering

#### k3s nodes

- **CPU**: Øg vCPU count
- **RAM**: Øg memory
- **Disk**: Øg disk størrelse

#### Prometheus

```yaml
# Infrastructure/monitoring/prometheus-values.yaml
prometheus:
  server:
    resources:
      requests:
        cpu: 2000m
        memory: 8Gi
      limits:
        cpu: 4000m
        memory: 16Gi
```

#### Loki

```yaml
# Infrastructure/monitoring/loki-values.yaml
loki:
  resources:
    requests:
      cpu: 2000m
      memory: 8Gi
    limits:
      cpu: 4000m
      memory: 16Gi
```

## Sikkerhed

### k3s

- **API adgang**: Kun tillad fra runner VM og admin IPs
- **Firewall**: Aktiver UFW
- **RBAC**: Minimal permissions til service accounts

### Backup

- **S3 credentials**: Gemt i sealed-secrets
- **Encryption**: Aktiver Velero encryption at rest
- **Retention**: Konfigurer retention policies

### Monitoring

- **Authentication**: Grafana basic auth
- **RBAC**: Grafana team/role permissions
- **Network policies**: Restriktioner på monitoring namespace

### Secrets

- **SealedSecrets**: Alle secrets gemt som SealedSecrets
- **kubeseal cert**: Gemt sikkert på runner VM
- **S3 credentials**: Gemt i sealed-secrets

## Nedetid procedurer

### k3s cluster nedetid

1. **Identificer problem**: `kubectl get nodes`
2. **Genstart k3s**: `sudo systemctl restart k3s`
3. **Hvis k3s ikke starter**: Tjek logs `sudo journalctl -u k3s -f`
4. **Hvis etcd korrupt**: Restore fra backup

### Tenant nedetid

1. **Tjek tenant status**: `kubectl get pods -n tenant-12345`
2. **Tjek logs**: `kubectl logs -n tenant-12345 <pod>`
3. **Restart pod**: `kubectl delete pod -n tenant-12345 <pod>`
4. **Hvis fortsat problemer**: Restore fra backup

### Backup nedetid

1. **Tjek Velero**: `kubectl get pods -n velero`
2. **Restart Velero**: `kubectl rollout restart deployment velero -n velero`
3. **Tjek S3**: `aws s3 ls s3://saasplatform-backups`
4. **Hvis S3 nede**: Vent på S3, genkør backup

## Kontakter

- **Primary**: admin@saasplatform.dk
- **Secondary**: support@saasplatform.dk
- **On-call**: +45 XX XX XX XX

## Dokumentation links

- [k3s Dokumentation](https://docs.k3s.io/)
- [Velero Dokumentation](https://velero.io/docs/)
- [Prometheus Dokumentation](https://prometheus.io/docs/)
- [Grafana Dokumentation](https://grafana.com/docs/)
- [Loki Dokumentation](https://grafana.com/docs/loki/latest/)
- [Cloudflare API](https://api.cloudflare.com/)
- [Wasabi S3 API](https://s3.wasabisys.com/)
- [SellYourSaaS Dokumentation](https://github.com/DoliCloud/sellyoursaas)
