# Fase 2 - Produktionsmiljø

## Overblik

Fase 2 fokuserer på at gøre systemet produktionsklar:
- **Produktions-k3s cluster** med Traefik, cert-manager, sealed-secrets
- **Velero backup** med Wasabi S3
- **Natlig DB-dump** for alle tenants
- **Canary-rollout rutine** for opdateringer
- **Observability stack** (Prometheus + Grafana + Loki)
- **Dashboards og alerts** for monitoring

## Exit-kriterier

| Kriterium | Status | Noter |
|-----------|--------|-------|
| Produktionsmiljø for begge deployment-typer | ⬜ | k3s + native |
| Velero + natlig DB-dump | ⬜ | Backup funktionel |
| Canary-rollout rutine | ⬜ | Automatisk opdatering |
| Dashboards og alerts | ⬜ | Monitoring funktionel |

## Komponenter

### 1. k3s Cluster

Se [Infrastructure/k3s](../../Infrastructure/k3s/README.md) for:
- Cluster opsætningsguide
- Traefik ingress controller
- cert-manager (Cloudflare DNS-01)
- sealed-secrets
- Metrics-server

### 2. Velero Backup

Se [Infrastructure/velero](../../Infrastructure/velero/README.md) for:
- Velero installation
- Wasabi S3 konfiguration
- Backup schedules
- Restore procedurer

### 3. Canary-rollout

Se [Scripts/canary-rollout.sh](../../Scripts/canary-rollout.sh) for:
- Canary-algoritme
- Rotationsindeks
- Fejlhåndtering (rollback)

### 4. Observability Stack

Se [Infrastructure/monitoring](../../Infrastructure/monitoring/README.md) for:
- Prometheus
- Grafana
- Loki
- Promtail
- Dashboards
- Alerts

## Opsætningsguide

### 1. Opret k3s cluster

Følg guiden i [Infrastructure/k3s/README.md](../../Infrastructure/k3s/README.md)

### 2. Opret Velero backup

Følg guiden i [Infrastructure/velero/README.md](../../Infrastructure/velero/README.md)

### 3. Opret Observability Stack

Følg guiden i [Infrastructure/monitoring/README.md](../../Infrastructure/monitoring/README.md)

### 4. Konfigurer Canary-rollout

#### 4.1 Opret rotationsindeks filer

```bash
# Opret mapper
sudo mkdir -p /var/lib/saasplatform

# Opret rotationsindeks filer for hver strata
for strata in standard premium; do
  for server in k8s-prod native-prod; do
    touch /var/lib/saasplatform/canary-index-${strata}-${server}.txt
    echo 0 > /var/lib/saasplatform/canary-index-${strata}-${server}.txt
  done
done

# Sæt permissions
sudo chown -R saasplatform:saasplatform /var/lib/saasplatform
```

#### 4.2 Konfigurer miljøvariabler

```bash
# I /etc/saasplatform/config
CANARY_PERCENTAGE=5  # 5% canary
CANARY_WINDOW=1800   # 30 minutter
```

### 5. Konfigurer natlig DB-dump

Natlig DB-dump køres allerede via Helm-chartet (CronJob).

Verificer at CronJob kører:

```bash
kubectl get cronjob -n tenant-12345 backup
```

### 6. Test canary-rollout

```bash
# Simuler canary-rollout
export SELLYOURSAAS_VERSION="23.0.2"
export CANARY_PERCENTAGE=10

# Kør canary-rollout
./Scripts/canary-rollout.sh
```

## Drift

### Backup verification

```bash
# Tjek Velero backups
velero backup get

# Tjek backup status
velero backup describe <backup-name>

# Tjek S3 indhold
aws s3 --endpoint-url https://s3.wasabisys.com ls s3://saasplatform-backups/ \
  --recursive
```

### Monitoring

#### Prometheus

```bash
# Port-forward
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Adgang: http://localhost:9090
```

#### Grafana

```bash
# Port-forward
kubectl port-forward -n monitoring svc/grafana 3000:80

# Adgang: http://localhost:3000
# Login: admin / <password fra secret>
```

#### Loki

```bash
# Port-forward
kubectl port-forward -n monitoring svc/loki 3100:3100

# Query logs
curl -G -s "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query={namespace="tenant-12345"}'
```

### Canary-rollout

#### Manually trigger canary

```bash
# Sæt ny version
export SELLYOURSAAS_VERSION="23.0.3"

# Kør canary-rollout
./Scripts/canary-rollout.sh
```

#### Check canary status

```bash
# Tjek canary tenants
kubectl get pods -n tenant-* -l app=dolibarr

# Tjek healthz
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  contract=${ns#tenant-}
  curl -fsS -o /dev/null -m 5 "https://${contract}.kunder.saasplatform.dk/healthz"
done
```

### Alerts

#### Tjek aktive alerts

```bash
# Via Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
sleep 2
curl http://localhost:9090/api/v1/alerts

# Via Grafana
# Gå til Alerts dashboard
```

#### Test alerts

```bash
# Simuler high CPU
kubectl run stress-test --image=stressng --restart=Never -- \
  --cpu 4 --cpu-load 100 --timeout 60s -n tenant-test1

# Vent 5 minutter
sleep 300

# Tjek alerts
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
sleep 2
curl http://localhost:9090/api/v1/alerts
```

## Fejlfinding

### k3s problems

Se [Infrastructure/k3s/README.md](../../Infrastructure/k3s/README.md#fejlfinding)

### Velero problems

Se [Infrastructure/velero/README.md](../../Infrastructure/velero/README.md#fejlfinding)

### Canary-rollout problems

```bash
# Tjek rotationsindeks
cat /var/lib/saasplatform/canary-index-*.txt

# Tjek logs
journalctl -u saasplatform-k8s -f

# Tjek tenant status
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  echo "Namespace: $ns"
  kubectl get pods -n $ns
  kubectl get helmrelease -n $ns
done
```

### Monitoring problems

Se [Infrastructure/monitoring/README.md](../../Infrastructure/monitoring/README.md#fejlfinding)

## Skalering

### Horisontal skalering

#### k3s nodes

```bash
# Tilføj ny node
curl -sfL https://get.k3s.io | K3S_URL=https://<master-ip>:6443 K3S_TOKEN=<token> sh -s - agent

# Tjek nodes
kubectl get nodes
```

#### Velero

```bash
# Skaler Velero controller
kubectl scale deployment velero -n velero --replicas=2
```

#### Monitoring

```bash
# Skaler Prometheus
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.server.replicaCount=2

# Skaler Grafana
helm upgrade grafana grafana/grafana \
  --namespace monitoring \
  --set replicaCount=2

# Skaler Loki
helm upgrade loki grafana/loki \
  --namespace monitoring \
  --set loki.replicaCount=2
```

### Vertikal skalering

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
- **Firewall**: Aktiver UFW (se [Infrastructure/k3s/README.md](../../Infrastructure/k3s/README.md#sikkerhed))
- **RBAC**: Minimal permissions til service accounts

### Backup

- **S3 credentials**: Gemt i sealed-secrets
- **Encryption**: Aktiver Velero encryption at rest
- **Retention**: Konfigurer retention policies

### Monitoring

- **Authentication**: Grafana basic auth
- **RBAC**: Grafana team/role permissions
- **Network policies**: Restriktioner på monitoring namespace

## Vedligeholdelse

### k3s opgradering

Se [Infrastructure/k3s/README.md](../../Infrastructure/k3s/README.md#vedligeholdelse)

### Certifikat fornyelse

cert-manager håndterer automatisk fornyelse af TLS certifikater.

Tjek status:
```bash
kubectl get certificate -A
kubectl describe certificate -n tenant-12345
```

### Backup verification

```bash
# Test restore
velero restore create --from-backup <backup-name> --dry-run

# Verificer backup indhold
velero backup describe <backup-name>
```

### Log rotation

```bash
# Grafana logs
kubectl logs -n monitoring deployment/grafana

# Prometheus logs
kubectl logs -n monitoring deployment/prometheus-kube-prometheus-prometheus

# Loki logs
kubectl logs -n monitoring deployment/loki
```

## Ressourcer

- [k3s Dokumentation](https://docs.k3s.io/)
- [Velero Dokumentation](https://velero.io/docs/)
- [Prometheus Dokumentation](https://prometheus.io/docs/)
- [Grafana Dokumentation](https://grafana.com/docs/)
- [Loki Dokumentation](https://grafana.com/docs/loki/latest/)
