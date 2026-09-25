# Observability Stack - Prometheus + Grafana + Loki

## Overblik

Observability stack til saasplatform:
- **Prometheus**: Metrics collection
- **Grafana**: Dashboards og visualisering
- **Loki**: Log aggregation
- **Promtail**: Log collection (Loki agent)

## Arkitektur

```
┌─────────────────────────────────────────────────────────────┐
│                    Observability Stack                         │
├─────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐      │
│  │  Prometheus  │◄───┤   Grafana    │    │    Loki      │      │
│  │   (metrics)  │    │  (dashboards)│    │   (logs)     │      │
│  └─────────────┘    └─────────────┘    └─────────────┘      │
│         ▲                  ▲                  ▲              │
│         │                  │                  │              │
│  ┌──────┴──────┐    ┌──────┴──────┐    ┌──────┴──────┐      │
│  │  Tenant     │    │  Tenant     │    │  Tenant     │      │
│  │  Metrics    │    │  Metrics    │    │  Logs       │      │
│  │  (Pods)     │    │  (Pods)     │    │  (Pods)     │      │
│  └─────────────┘    └─────────────┘    └─────────────┘      │
│                                                                  │
└─────────────────────────────────────────────────────────────┘
```

## Forudsætninger

- k3s cluster (se [Infrastructure/k3s](../k3s))
- kubectl adgang
- Helm
- StorageClass (local-path, NFS, etc.)

## Installation

### 1. Opret namespace

```bash
kubectl create namespace monitoring
```

### 2. Installer Prometheus

```bash
# Tilføj Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Installer Prometheus
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f Infrastructure/monitoring/prometheus-values.yaml

# Verificer
kubectl get pods -n monitoring | grep prometheus
kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus
```

### 3. Installer Grafana

```bash
# Tilføj Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Installer Grafana
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --create-namespace \
  -f Infrastructure/monitoring/grafana-values.yaml

# Hent admin password
kubectl get secret -n monitoring grafana -o jsonpath='{.data.admin-password}' | base64 --decode

# Verificer
kubectl get pods -n monitoring | grep grafana
kubectl get svc -n monitoring grafana
```

### 4. Installer Loki

```bash
# Tilføj Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Installer Loki
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --create-namespace \
  -f Infrastructure/monitoring/loki-values.yaml

# Verificer
kubectl get pods -n monitoring | grep loki
kubectl get svc -n monitoring loki
```

### 5. Installer Promtail

```bash
# Installer Promtail (Loki agent)
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --create-namespace \
  -f Infrastructure/monitoring/promtail-values.yaml

# Verificer
kubectl get pods -n monitoring | grep promtail
```

### 6. Konfigurer datasources i Grafana

```bash
# Opret ConfigMap med datasources
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      access: proxy
      url: http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090
      isDefault: true
      editable: false
  loki.yaml: |
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc:3100
      editable: false
EOF

# Restart Grafana for at loade datasources
kubectl rollout restart deployment grafana -n monitoring
```

### 7. Importer dashboards

```bash
# Importer saasplatform dashboards
kubectl apply -f Infrastructure/monitoring/dashboards/

# Eller manuelt via Grafana UI:
# 1. Gå til http://<grafana-ip>:3000
# 2. Login (admin / <password fra secret>)
# 3. Gå til Dashboards -> Import
# 4. Upload JSON filer fra Infrastructure/monitoring/dashboards/
```

## Konfiguration

### Prometheus

Se [prometheus-values.yaml](prometheus-values.yaml) for:
- Scrape intervals
- Retention policies
- Alertmanager integration
- Resource limits

### Grafana

Se [grafana-values.yaml](grafana-values.yaml) for:
- Admin credentials
- Persistence
- Ingress configuration
- Plugins

### Loki

Se [loki-values.yaml](loki-values.yaml) for:
- Storage configuration
- Retention policies
- Resource limits

### Promtail

Se [promtail-values.yaml](promtail-values.yaml) for:
- Log collection paths
- Labels
- Filters

## Dashboards

### Tenant Overview Dashboard

Visuel oversigt over alle tenants:
- **CPU/Memory usage** pr. tenant
- **Pod status** (Running, Pending, Failed)
- **Healthz status** (OK, Unhealthy)
- **Backup status** (Seneste backup tidspunkt)

### Resource Usage Dashboard

Monitorering af cluster ressourcer:
- **CPU usage** (total, pr. node, pr. tenant)
- **Memory usage** (total, pr. node, pr. tenant)
- **Storage usage** (PVC usage)
- **Network I/O**

### Alerts Dashboard

Visuel oversigt over aktive alerts:
- **Critical alerts** (rød)
- **Warning alerts** (gul)
- **Info alerts** (blå)

### Tenant Detail Dashboard

Detaljeret view for en specifik tenant:
- **Pods** (status, restarts, logs)
- **Resources** (CPU, Memory, Storage)
- **Network** (ingress, egress)
- **Events** (Kubernetes events)

## Alerts

### Prometheus Alert Rules

```yaml
# Infrastructure/monitoring/alerts.yaml
groups:
- name: kubernetes.rules
  rules:
  
  # Node alerts
  - alert: NodeHighCPU
    expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High CPU usage on {{ $labels.instance }}"
      description: "CPU usage is {{ $value }}%"

  - alert: NodeHighMemory
    expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 90
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High memory usage on {{ $labels.instance }}"
      description: "Memory usage is {{ $value }}%"

  - alert: NodeDiskFull
    expr: node_filesystem_free_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100 < 10
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Disk almost full on {{ $labels.instance }}"
      description: "Disk usage is {{ $value }}%"

  # Tenant alerts
  - alert: TenantUnhealthy
    expr: up{job="kubernetes-pods", namespace=~"tenant-.*"} == 0
    for: 5m
    labels:
      severity: critical
      tenant: "{{ $labels.namespace }}"
    annotations:
      summary: "Tenant {{ $labels.namespace }} is unhealthy"
      description: "Healthz check failed for {{ $labels.namespace }}"

  - alert: TenantHighCPU
    expr: sum by(namespace) (rate(container_cpu_usage_seconds_total{namespace=~"tenant-.*"}[5m])) / sum by(namespace) (container_spec_cpu_quota{namespace=~"tenant-.*"} / container_spec_cpu_period{namespace=~"tenant-.*"}) * 100 > 80
    for: 10m
    labels:
      severity: warning
      tenant: "{{ $labels.namespace }}"
    annotations:
      summary: "High CPU usage for tenant {{ $labels.namespace }}"
      description: "CPU usage is {{ $value }}%"

  - alert: TenantHighMemory
    expr: sum by(namespace) (container_memory_working_set_bytes{namespace=~"tenant-.*"}) / sum by(namespace) (container_spec_memory_limit_bytes{namespace=~"tenant-.*"}) * 100 > 80
    for: 10m
    labels:
      severity: warning
      tenant: "{{ $labels.namespace }}"
    annotations:
      summary: "High memory usage for tenant {{ $labels.namespace }}"
      description: "Memory usage is {{ $value }}%"

  # Backup alerts
  - alert: VeleroBackupFailed
    expr: velero_backup_failed_total > 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Velero backup failed"
      description: "Backup {{ $labels.backup }} failed"

  # cert-manager alerts
  - alert: CertificateExpiringSoon
    expr: (certmanager_certificate_expiration_seconds / 86400) < 7
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Certificate expiring soon"
      description: "Certificate {{ $labels.name }} expires in {{ $value }} days"

  - alert: CertificateExpired
    expr: certmanager_certificate_expiration_seconds < 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Certificate expired"
      description: "Certificate {{ $labels.name }} has expired"
```

### Alertmanager Configuration

```yaml
# Infrastructure/monitoring/alertmanager-values.yaml
alertmanager:
  enabled: true
  config:
    global:
      resolve_timeout: 5m
      slack_api_url: "https://hooks.slack.com/services/..."
    
    route:
      group_by: ['alertname', 'severity']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 3h
      receiver: 'slack-notifications'
      
      routes:
      - match:
          severity: critical
        receiver: 'slack-critical'
        group_interval: 1m
        repeat_interval: 1h
      
      - match:
          severity: warning
        receiver: 'slack-warning'
        group_interval: 5m
        repeat_interval: 2h
    
    receivers:
    - name: 'slack-notifications'
      slack_configs:
      - channel: '#alerts'
        send_resolved: true
        text: '{{ template "slack.saasplatform.text" . }}'
    
    - name: 'slack-critical'
      slack_configs:
      - channel: '#critical-alerts'
        send_resolved: true
        color: 'danger'
        text: '{{ template "slack.saasplatform.critical.text" . }}'
    
    - name: 'slack-warning'
      slack_configs:
      - channel: '#warnings'
        send_resolved: true
        color: 'warning'
        text: '{{ template "slack.saasplatform.warning.text" . }}'
```

## Skalerings-triggere

Fra [Arkitektur.md](../../Docs/Arkitektur.md#36-observability-og-skaleringsmål):

| **Komponent** | **Metric** | **Trigger** | **Action** |
|--------------|-----------|-------------|------------|
| Loki | p99 query latency > 2s | ~200 tenants | Revurder Loki setup |
| Prometheus | > 1M aktive time-series | ~100 tenants | Reducer labels, sharding |
| k3s-cluster | > 500 pods | > 80% RAM | Capsule/vCluster |

## Adgang

### Port-forwarding (udvikling)

```bash
# Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# Loki
kubectl port-forward -n monitoring svc/loki 3100:3100
```

### Ingress (produktion)

```yaml
# Infrastructure/monitoring/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - monitoring.saasplatform.dk
    secretName: monitoring-tls
  rules:
  - host: monitoring.saasplatform.dk
    http:
      paths:
      - path: /prometheus
        pathType: Prefix
        backend:
          service:
            name: prometheus-kube-prometheus-prometheus
            port:
              number: 9090
      - path: /grafana
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
      - path: /loki
        pathType: Prefix
        backend:
          service:
            name: loki
            port:
              number: 3100
```

## Sikkerhed

### Authentication

```yaml
# Grafana basic auth
# Se: grafana-values.yaml
grafana.ini:
  auth:
    disable_login_form: false
    disable_signout_menu: false
  
  auth.anonymous:
    enabled: false
  
  auth.basic:
    enabled: true
```

### RBAC

```bash
# Opret Grafana admin bruger via CLI
kubectl exec -it -n monitoring deployment/grafana -- \
  grafana-cli admin reset-admin-password --homepath=/usr/share/grafana newpassword
```

### Network Policies

```yaml
# Tillad kun monitoring namespace at tilgå Prometheus
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prometheus-access
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app: kube-prometheus-stack-prometheus
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 9090
```

## Vedligeholdelse

### Backup af Prometheus data

```bash
# Prometheus data er i en PVC
kubectl get pvc -n monitoring | grep prometheus

# Backup via Velero
velero backup create monitoring-backup \
  --include-namespaces monitoring \
  --ttl 7d
```

### Opgradering

```bash
# Opgrader Prometheus
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f Infrastructure/monitoring/prometheus-values.yaml

# Opgrader Grafana
helm upgrade grafana grafana/grafana \
  --namespace monitoring \
  -f Infrastructure/monitoring/grafana-values.yaml

# Opgrader Loki
helm upgrade loki grafana/loki \
  --namespace monitoring \
  -f Infrastructure/monitoring/loki-values.yaml
```

## Fejlfinding

### Prometheus fungerer ikke

```bash
# Tjek pods
kubectl get pods -n monitoring | grep prometheus

# Tjek logs
kubectl logs -n monitoring deployment/prometheus-kube-prometheus-prometheus

# Tjek targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
sleep 2
curl http://localhost:9090/targets
```

### Grafana fungerer ikke

```bash
# Tjek pods
kubectl get pods -n monitoring | grep grafana

# Tjek logs
kubectl logs -n monitoring deployment/grafana

# Tjek service
kubectl get svc -n monitoring grafana
```

### Loki fungerer ikke

```bash
# Tjek pods
kubectl get pods -n monitoring | grep loki

# Tjek logs
kubectl logs -n monitoring deployment/loki

# Tjek storage
kubectl get pvc -n monitoring | grep loki
```

### Promtail fungerer ikke

```bash
# Tjek pods
kubectl get pods -n monitoring | grep promtail

# Tjek logs
kubectl logs -n monitoring daemonset/promtail

# Tjek config
kubectl get cm -n monitoring promtail-config -o yaml
```

## Ressourcer

- [Prometheus Dokumentation](https://prometheus.io/docs/)
- [Grafana Dokumentation](https://grafana.com/docs/)
- [Loki Dokumentation](https://grafana.com/docs/loki/latest/)
- [Promtail Dokumentation](https://grafana.com/docs/loki/latest/clients/promtail/)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
