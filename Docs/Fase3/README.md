# Fase 3 - Skalering, High Availability og Disaster Recovery

## Formaal

Implementere **produktionsgrad skalering, high availability (HA) og disaster recovery (DR)** for saasplatform:
- **Horisontal skalering** af k3s cluster og tenants
- **High Availability** for alle kritiske komponenter
- **Disaster Recovery** procedurer og runbooks
- **Multi-region** deployment (fremtidig)
- **Auto-scaling** (HPA, cluster-autoscaler)

**Exit-kriterier:**
- k3s cluster kan skaleres horisontalt (3+ nodes)
- Kritiske komponenter har HA konfiguration
- Disaster recovery procedurer er testet og dokumenteret
- RTO (Recovery Time Objective) < 1 time
- RPO (Recovery Point Objective) < 15 minutter

---

## Overblik

Fase 3 bygger oven paa fase 2 (produktionsdrift) og tilfoejer:

1. **Skalering**
   - Horisontal skalering af k3s nodes
   - Vertikal skalering af kritiske pods
   - Auto-scaling (HPA for tenants, cluster-autoscaler for nodes)
   - Storage skalering (PVC resizing, storage classer)

2. **High Availability**
   - Multi-node k3s cluster (1 master + 2+ workers)
   - HA for Traefik, Prometheus, Grafana, Loki
   - Database HA (MariaDB Galera cluster eller proxy)
   - Multi-AZ deployment (fremtidig)

3. **Disaster Recovery**
   - Full cluster backup/restore
   - Etcd backup og restore
   - Tenant disaster recovery
   - DR runbooks og test procedurer

4. **Monitoring og Alerting**
   - Avanceret monitoring for HA/DR
   - SLA/SLO tracking
   - Incident response procedurer

---

## Arkitektur Reference

Se [Arkitektur.md](../Arkitektur.md) for:
- §3.7: Runner placering og permissions
- §3.6: Observability (udvidet for HA/DR)

---

## Forudsætninger

- [ ] Fase 2 er faerdig (produktionsdrift fungerer)
- [ ] k3s cluster koerer med 1+ master og 1+ worker
- [ ] Alle tenants deployet og fungerer
- [ ] Backup infrastructure (Velero + Wasabi S3) fungerer
- [ ] Monitoring stack (Prometheus + Grafana + Loki) fungerer
- [ ] Canary-rollout fungerer

---

## 1. Skalering

### 1.1 Horisontal Skalering (k3s Nodes)

#### k3s Cluster Skalering

**k3s arkitektur:**
- **Master node:** Koerer etcd, k3s API, scheduler, controller-manager
- **Worker nodes:** Koerer kubelet, containerd, og workloads
- **Max nodes:** k3s understotter op til 100+ nodes (afhaengig af hardware)

**Skaler op (tilfoej worker node):**
```bash
# Paa ny worker node (Ubuntu 22.04)
# Forudsat: SSH-adgang fra master, firewall tillader port 6443

# Installer k3s agent
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<master-ip>:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-label "node-role.kubernetes.io/worker=true" \
  --node-label "topology.kubernetes.io/zone=<az>"

# Verificer
kubectl get nodes
```

**Skaler ned (fjern worker node):**
```bash
# 1. Drain node (flyt workloads til andre nodes)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. Fjern node fra cluster
kubectl delete node <node-name>

# 3. Paa node: Stop k3s agent
sudo systemctl stop k3s-agent
sudo systemctl disable k3s-agent

# 4. (Valgfrit) Geninstaller node for at tilfoje igen senere
```

#### Node Labels og Taints

**Labels for skalering:**
```bash
# Saet labels paa node
kubectl label node <node-name> \
  node-role.kubernetes.io/worker=true \
  topology.kubernetes.io/zone=zone-a \
  saasplatform.dk/node-type=standard

# Tjek labels
kubectl get nodes --show-labels
```

**Taints for dedikerede nodes:**
```bash
# Taint node for dedikerede workloads (fx database)
kubectl taint nodes <node-name> \
  dedicated=database:NoSchedule

# Fjern taint
kubectl taint nodes <node-name> dedicated=database:NoSchedule-
```

#### Node Affinity for Tenants

**Premium tenants paa dedikerede nodes:**
```yaml
# I values.yaml for premium tenants
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: saasplatform.dk/node-type
              operator: In
              values:
                - premium
```

### 1.2 Vertikal Skalering (Resources)

#### Tenant Resource Skalering

**Standard vs. Premium tenants:**

| Plan | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|------|-------------|-----------|----------------|--------------|---------|
| Standard | 100m | 2 | 256Mi | 1Gi | 5Gi |
| Premium | 500m | 4 | 1Gi | 4Gi | 20Gi |
| Enterprise | 1 | 8 | 4Gi | 8Gi | 50Gi |

**Skaler en tenant:**
```bash
# Opdater values-fil
kubectl edit cm -n tenant-12345 tenant-values
# Eller via Helm
helm upgrade tenant-12345 Helm/erp-tenant \
  -n tenant-12345 \
  -f values.yaml \
  --set dolibarr.resources.requests.cpu=500m \
  --set dolibarr.resources.requests.memory=1Gi \
  --set db.storage=20Gi
```

#### Cluster Resource Skalering

**k3s Master resources:**
```bash
# Rediger k3s service
sudo systemctl edit k3s

# Tilfoej/opdater:
[Service]
CPUQuota=50%
MemoryLimit=8G

# Genstart
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

### 1.3 Auto-Scaling

#### Horizontal Pod Autoscaler (HPA)

**Enable HPA for Dolibarr:**
```yaml
# I values.yaml
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 3  # Limited by ReadWriteOnce PVC
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
```

**HPA Template (90-hpa.yaml):**
```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dolibarr
  namespace: {{ .Release.Namespace }}
  labels:
    app: dolibarr
    tenant: {{ .Values.instance | quote }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dolibarr
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    {{- if .Values.autoscaling.targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
    {{- end }}
    {{- if .Values.autoscaling.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetMemoryUtilizationPercentage }}
    {{- end }}
{{- end -}}
```

**Note:** HPA er **deaktiveret som default** pga. ReadWriteOnce PVC begrensning.

#### Cluster Autoscaler

**Installer cluster-autoscaler:**
```bash
# Tilfoej repo
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

# Installer (for k3s)
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version 9.27.0 \
  --set autoDiscovery.clusterName=k3s-cluster \
  --set extraArgs.scale-down-enabled=true \
  --set extraArgs.scale-down-delay-after-add=10m \
  --set extraArgs.scale-down-delay-after-delete=5m \
  --set extraArgs.scale-down-unneeded-time=5m \
  --set extraArgs.skip-nodes-with-local-storage=false \
  --set rbac.create=true
```

**Konfigurer node auto-provisioning:**
```bash
# Opret ClusterAutoscaler CRD
cat > Infrastructure/autoscaler/cluster-autoscaler.yaml << 'EOF'
apiVersion: kubernetes-autoscaler.autoscaler.k8s.io/v1beta1
kind: ClusterAutoscaler
metadata:
  name: k3s-autoscaler
spec:
  scaleDown:
    enabled: true
    delayAfterAdd: 10m
    delayAfterDelete: 5m
    unneededTime: 5m
  podPriorityThreshold: -10
  resourceLimits:
    maxNodesTotal: 10
    cores:
      min: 4
      max: 32
    memory:
      min: 8
      max: 128
EOF
```

### 1.4 Storage Skalering

#### PVC Resizing

**Resizing af eksisterende PVC:**
```bash
# 1. Rediger PVC
kubectl edit pvc -n tenant-12345 documents

# 2. Opdater storage request
# Fra: storage: 5Gi
# Til: storage: 10Gi

# 3. PVC vil automatisk blive resized (hvis storage class understotter det)
# 4. Verificer
kubectl get pvc -n tenant-12345 documents
```

**Storage Classer:**
```yaml
# Infrastructure/storage/storage-classes.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
provisioner: local
parameters:
  type: fast
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: slow
provisioner: local
parameters:
  type: slow
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
```

---

## 2. High Availability

### 2.1 k3s High Availability

#### Multi-Master k3s (HA)

**k3s HA arkitektur:**
- 3+ master nodes med etcd cluster
- Embedded HAProxy for load balancing
- Automatic failover

**Setup HA k3s cluster:**
```bash
# Paa første master node (initialiser cluster)
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san <master1-ip> \
  --tls-san <master2-ip> \
  --tls-san <master3-ip> \
  --tls-san <loadbalancer-ip>

# Gem K3S_TOKEN og K3S_URL
K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)
K3S_URL=https://<master1-ip>:6443

# Paa master node 2
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<master1-ip>:6443 \
  --token $K3S_TOKEN \
  --tls-san <master2-ip>

# Paa master node 3
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<master1-ip>:6443 \
  --token $K3S_TOKEN \
  --tls-san <master3-ip>
```

**Load Balancer for HA:**
```bash
# Installer HAProxy (eller brug cloud load balancer)
sudo apt install -y haproxy

# Konfigurer /etc/haproxy/haproxy.cfg
cat > /etc/haproxy/haproxy.cfg << 'EOF'
frontend k3s
  bind *:6443
  mode tcp
  default_backend k3s_masters

backend k3s_masters
  mode tcp
  balance roundrobin
  server master1 <master1-ip>:6443 check
  server master2 <master2-ip>:6443 check
  server master3 <master3-ip>:6443 check
EOF

# Genstart HAProxy
sudo systemctl restart haproxy
```

**Verificer HA:**
```bash
# Tjek etcd cluster health
sudo k3s etcd snapshot save --name test-snapshot

# Tjek k3s nodes
kubectl get nodes -o wide

# Tjek etcd members
sudo k3s etcdctl member list
```

#### etcd Backup og Restore

**Automatisk etcd backup:**
```bash
# k3s har indbygget etcd backup
# Snapshots gemmes i /var/lib/rancher/k3s/server/db/snapshots/

# Tjek backup status
sudo ls -la /var/lib/rancher/k3s/server/db/snapshots/

# Konfigurer automatisk backup (cron)
cat > /etc/cron.d/k3s-etcd-backup << 'EOF'
0 3 * * * root k3s etcd snapshot save --name daily-$(date +%Y%m%d) --s3-endpoint=s3.eu-central-1.wasabisys.com --s3-bucket=k3s-backups --s3-access-key=$WASABI_ACCESS_KEY --s3-secret-key=$WASABI_SECRET_KEY
EOF
```

**etcd Restore:**
```bash
# 1. Stop k3s
sudo systemctl stop k3s

# 2. Restore fra snapshot
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>

# 3. Start k3s
sudo systemctl start k3s
```

### 2.2 Traefik High Availability

**Traefik HA med multiple replicas:**
```yaml
# Infrastructure/traefik/values-ha.yaml
replicaCount: 3

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi

nodeSelector:
  node-role.kubernetes.io/worker: "true"

tolerations:
  - key: "node-role.kubernetes.io/master"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

**Deploy Traefik HA:**
```bash
helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --version 25.0.0 \
  -f Infrastructure/traefik/values-ha.yaml
```

### 2.3 Prometheus High Availability

**Prometheus HA med Thanos:**
```yaml
# Infrastructure/monitoring/prometheus-ha-values.yaml
prometheus:
  server:
    replicaCount: 2
    retention: 15d
    retentionSize: "100GiB"
    
  thanos:
    enabled: true
    image: thanosio/thanos:v0.32.0
    
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1

alertmanager:
  replicaCount: 2
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1
```

### 2.4 Database High Availability

#### Option 1: MariaDB Galera Cluster

**Galera cluster for MariaDB:**
```yaml
# Helm/erp-tenant/templates/30-mariadb-statefulset-ha.yaml
{{- if .Values.db.ha.enabled -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mariadb
  namespace: {{ .Release.Namespace }}
  labels:
    app: mariadb
    tenant: {{ .Values.instance | quote }}
    app.kubernetes.io/managed-by: saasplatform
    app.kubernetes.io/component: db
spec:
  serviceName: mariadb
  replicas: 3
  selector:
    matchLabels:
      app: mariadb
      app.kubernetes.io/component: db
      tenant: {{ .Values.instance | quote }}
  template:
    metadata:
      labels:
        app: mariadb
        app.kubernetes.io/component: db
        tenant: {{ .Values.instance | quote }}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - mariadb
              topologyKey: kubernetes.io/hostname
      containers:
        - name: mariadb
          image: mariadb:11.4-galera
          env:
            - name: WSREP_CLUSTER_NAME
              value: "{{ .Values.instance }}-galera"
            - name: WSREP_CLUSTER_MEMBERSHIP
              value: "gcomm://mariadb-0.mariadb.{{ .Release.Namespace }}.svc.cluster.local,mariadb-1.mariadb.{{ .Release.Namespace }}.svc.cluster.local,mariadb-2.mariadb.{{ .Release.Namespace }}.svc.cluster.local"
            - name: WSREP_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
{{- end -}}
```

#### Option 2: ProxySQL for MariaDB

**ProxySQL load balancer:**
```yaml
# Helm/erp-tenant/templates/35-proxysql.yaml
{{- if .Values.db.proxysql.enabled -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: proxysql
  namespace: {{ .Release.Namespace }}
  labels:
    app: proxysql
    tenant: {{ .Values.instance | quote }}
    app.kubernetes.io/managed-by: saasplatform
spec:
  replicas: 2
  selector:
    matchLabels:
      app: proxysql
      tenant: {{ .Values.instance | quote }}
  template:
    metadata:
      labels:
        app: proxysql
        tenant: {{ .Values.instance | quote }}
    spec:
      containers:
        - name: proxysql
          image: proxysql/proxysql:2.5.0
          env:
            - name: MYSQL_BACKEND_SERVERS
              value: "mariadb.{{ .Release.Namespace }}.svc.cluster.local:3306"
          ports:
            - containerPort: 6033
              name: mysql
          volumeMounts:
            - name: config
              mountPath: /etc/proxysql.cnf
              subPath: proxysql.cnf
      volumes:
        - name: config
          configMap:
            name: proxysql-config
{{- end -}}
```

---

## 3. Disaster Recovery

### 3.1 Disaster Recovery Plan

#### DR Scenarier

| Scenarie | Beskrivelse | RTO | RPO | Prioritet |
|----------|-------------|-----|-----|-----------|
| **Cluster Nedetid** | Alle k3s nodes nede | < 30 min | < 5 min | Kritisk |
| **Single Node Failure** | 1 node fejler | < 10 min | 0 | Høj |
| **Storage Failure** | PVC data tabt | < 1 time | < 15 min | Høj |
| **Database Korruption** | MariaDB data korrupt | < 1 time | < 15 min | Kritisk |
| **Region Outage** | Hele region nede | < 4 timer | < 1 time | Medium |
| **Tenant Data Loss** | Enkelt tenant data tabt | < 30 min | < 5 min | Høj |

#### DR Team og Kontakter

| Rolle | Navn | Telefon | Email | Slack |
|-------|------|---------|-------|-------|
| **Primary On-Call** | | +45 XX XX XX XX | oncall@saasplatform.dk | @oncall |
| **Secondary On-Call** | | +45 XX XX XX XX | oncall2@saasplatform.dk | @oncall2 |
| **Database Specialist** | | +45 XX XX XX XX | db@saasplatform.dk | @db-team |
| **Infrastructure Lead** | | +45 XX XX XX XX | infra@saasplatform.dk | @infra |

### 3.2 Backup Strategi

#### Backup Typer

| Backup Type | Frekvens | Retention | Storage | Formaal |
|-------------|----------|-----------|---------|---------|
| **etcd Snapshot** | Hver 6 timer | 7 dage | Wasabi S3 | Cluster state |
| **Tenant DB Dump** | Daglig kl. 02:00 | 7/30 dage | Wasabi S3 | Tenant data |
| **Tenant PVC** | Daglig kl. 03:00 | 7/30 dage | Wasabi S3 | Documents |
| **Full Cluster Backup** | Ugentlig | 4 uger | Wasabi S3 | Full restore |
| **Pre-Migration Snapshot** | Foor migrering | 30 dage | Wasabi S3 | Rollback |

#### Backup Verifikation

**Daglig backup verifikation:**
```bash
# Tjek Velero backups
velero backup get --sort-by=.status.completionTimestamp --reverse

# Tjek seneste backup status
velero backup get <latest> -o yaml | grep -E "(status|completionTimestamp)"

# Tjek backup stoerrelse
velero backup describe <latest> | grep "Total Items"

# Tjek S3 indhold
aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com ls s3://saasplatform-backups/ --recursive --summarize
```

### 3.3 Cluster Disaster Recovery

#### Full Cluster Restore

**Scenarie:** Hele k3s cluster er nede og skal genskabes fra bunden.

**Steps:**

1. **Forbered nye servere**
   ```bash
   # Opret nye VMs (samme spec som originale)
   # Installer Ubuntu 22.04 LTS
   # Konfigurer SSH-adgang
   ```

2. **Installer k3s paa nye servere**
   ```bash
   # Paa master node 1 (initialiser cluster)
   curl -sfL https://get.k3s.io | sh -s - server \
     --cluster-init \
     --tls-san <master1-ip> \
     --tls-san <master2-ip> \
     --tls-san <master3-ip>
   
   # Gem K3S_TOKEN
   K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)
   
   # Paa master node 2 og 3
   curl -sfL https://get.k3s.io | sh -s - server \
     --server https://<master1-ip>:6443 \
     --token $K3S_TOKEN
   ```

3. **Restore etcd fra backup**
   ```bash
   # Paa master node 1
   sudo systemctl stop k3s
   
   # Download seneste etcd snapshot
   aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com cp \
     s3://k3s-backups/etcd-daily-$(date +%Y%m%d).snapshot \
     /var/lib/rancher/k3s/server/db/snapshots/restore.snapshot
   
   # Restore
   sudo k3s server \
     --cluster-reset \
     --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/restore.snapshot
   
   sudo systemctl start k3s
   ```

4. **Verificer cluster**
   ```bash
   # Tjek nodes
   kubectl get nodes
   
   # Tjek etcd health
   sudo k3s etcdctl endpoint health --endpoints=https://127.0.0.1:2379
   
   # Tjek system pods
   kubectl get pods -A
   ```

5. **Restore infrastructure komponenter**
   ```bash
   # Traefik
   helm upgrade --install traefik traefik/traefik \
     --namespace kube-system \
     -f Infrastructure/traefik/values.yaml
   
   # cert-manager
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
   helm upgrade --install cert-manager jetstack/cert-manager \
     --namespace cert-manager \
     --version v1.14.4 \
     --set installCRDs=true
   
   # SealedSecrets
   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.22.0/controller.yaml
   
   # Velero
   velero install \
     --provider aws \
     --plugins velero/velero-plugin-for-aws:v1.4.0 \
     --bucket saasplatform-backups \
     --backup-location-config region=eu-central-1,s3ForcePathStyle=true,s3Url=https://s3.eu-central-1.wasabisys.com \
     --snapshot-location-config region=eu-central-1 \
     --secret-file ./Infrastructure/velero/wasabi-credentials \
     --namespace velero
   
   # Monitoring
   helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
     --namespace monitoring \
     -f Infrastructure/monitoring/prometheus-values.yaml
   ```

6. **Restore tenants**
   ```bash
   # List alle tenant backups
   velero backup get --label-selector saasplatform.dk/tenant=true
   
   # Restore alle tenants
   for backup in $(velero backup get -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n'); do
     velero restore create --from-backup $backup --wait
   done
   ```

### 3.4 Tenant Disaster Recovery

#### Single Tenant Restore

**Scenarie:** En enkelt tenant er korrupt eller skal genskabes.

**Steps:**

1. **Identificer tenant backup**
   ```bash
   velero backup get --include-namespaces tenant-12345
   ```

2. **Slet eksisterende tenant**
   ```bash
   ./Scripts/undeploy.sh 12345
   ```

3. **Restore tenant**
   ```bash
   # Find seneste backup
   BACKUP=$(velero backup get --include-namespaces tenant-12345 --sort-by=.status.completionTimestamp --reverse -o jsonpath='{.items[0].metadata.name}')
   
   # Restore
   velero restore create tenant-12345-restore-$(date +%Y%m%d%H%M%S) \
     --from-backup $BACKUP \
     --include-namespaces tenant-12345 \
     --wait
   ```

4. **Verificer tenant**
   ```bash
   # Tjek pods
   kubectl get pods -n tenant-12345
   
   # Tjek healthz
   ./Scripts/cron.sh 12345
   
   # Tjek DNS
   dig +short 12345.kunder.saasplatform.dk
   ```

### 3.5 Database Disaster Recovery

#### MariaDB Restore fra Backup

**Scenarie:** MariaDB database er korrupt og skal genskabes.

**Steps:**

1. **Tag backup af nuværende (korrupte) data**
   ```bash
   ./Scripts/beforeundeploy.sh 12345
   ```

2. **Slet MariaDB StatefulSet**
   ```bash
   kubectl delete statefulset mariadb -n tenant-12345
   kubectl delete pvc -n tenant-12345 --all
   ```

3. **Restore fra DB dump**
   ```bash
   # Find seneste DB dump i S3
   DB_DUMP=$(aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com ls s3://saasplatform-backups/daily/tenant-12345/ | grep -i backup | tail -1 | awk '{print $4}')
   
   # Download dump
   aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com cp \
     s3://saasplatform-backups/daily/tenant-12345/$DB_DUMP \
     /tmp/restore.sql.gz
   
   # Deploy tenant med suspended=true (for at stoppe app pods)
   helm upgrade --install tenant-12345 Helm/erp-tenant \
     -n tenant-12345 \
     -f values-tenant-12345.yaml \
     --set suspended=true
   
   # Vent paa MariaDB pod
   kubectl wait --for=condition=Ready pod -n tenant-12345 -l app=mariadb --timeout=300s
   
   # Restore DB dump
   kubectl exec -n tenant-12345 pod/mariadb-0 -- \
     sh -c "zcat /tmp/restore.sql.gz | mysql -u \$MARIADB_USER -p\$MARIADB_PASSWORD dolibarr"
   
   # Unsuspend tenant
   helm upgrade tenant-12345 Helm/erp-tenant \
     -n tenant-12345 \
     -f values-tenant-12345.yaml \
     --set suspended=false
   ```

---

## 4. Monitoring og Alerting for HA/DR

### 4.1 HA/DR Metrikker

**Prometheus alerts for HA/DR:**
```yaml
# Infrastructure/monitoring/ha-dr-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ha-dr-alerts
  namespace: monitoring
spec:
  groups:
    - name: ha.rules
      rules:
        - alert: ClusterNodeDown
          expr: up{job="kube-state-metrics", metric="kube_node_status_condition"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Cluster node {{ $labels.node }} is down"
            description: "Node {{ $labels.node }} has been down for more than 5 minutes"

        - alert: HighNodeFailure
          expr: count(kube_node_status_condition{condition="Ready", status="true"} == 0) > 1
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Multiple nodes are down"
            description: "{{ $value }} nodes are down"

        - alert: etcdHighCommitLatency
          expr: histogram_quantile(0.99, rate(etcd_server_peer_commit_latency_seconds_bucket[5m])) > 0.5
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "High etcd commit latency"
            description: "etcd commit latency is {{ $value }}s"

        - alert: etcdNoLeader
          expr: etcd_server_leader_changes_total > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "etcd has no leader"
            description: "etcd cluster has no leader"

    - name: dr.rules
      rules:
        - alert: BackupFailure
          expr: velero_backup_failed_total > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Velero backup failed"
            description: "Velero backup {{ $labels.backup }} failed"

        - alert: NoRecentBackup
          expr: time() - max(velero_backup_completion_timestamp) > 86400
          labels:
            severity: warning
          annotations:
            summary: "No recent Velero backup"
            description: "No Velero backup in the last 24 hours"

        - alert: TenantDown
          expr: up{namespace=~"tenant-.*"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Tenant {{ $labels.namespace }} is down"
            description: "Tenant {{ $labels.namespace }} healthz check failed"
```

### 4.2 Grafana Dashboards for HA/DR

**HA/DR Dashboard:**
- Cluster node status
- etcd health
- Backup status (Velero)
- Tenant health overview
- Resource utilization
- Storage capacity

**Incident Response Dashboard:**
- Active alerts
- Recent incidents
- On-call rotation
- SLA compliance

---

## 5. Test og Verifikation

### 5.1 HA Test Procedurer

#### Test 1: Single Node Failure

**Formaal:** Verificere at cluster fortsaetter med at fungere ved node failure.

**Steps:**
```bash
# 1. Identificer en worker node
NODE=$(kubectl get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{.items[0].metadata.name}')

# 2. Drain node (simuler failure)
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data

# 3. Vent 5 minutter
sleep 300

# 4. Verificer cluster status
kubectl get nodes
kubectl get pods -A

# 5. Verificer tenants
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  if ! kubectl get pods -n $ns -l app=dolibarr --no-headers | grep -q Running; then
    echo "FAIL: Tenant $ns ikke korer"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done

if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "PASS: Alle tenants korer efter node failure"
else
  echo "FAIL: $FAILED_TENANTS tenants korer ikke"
fi

# 6. Genoptag node
kubectl uncordon $NODE
```

**Expected Result:**
- Cluster fortsaetter med at fungere
- Alle tenants korer (måske med nedsat performance)
- Ingen data tabt

#### Test 2: Master Node Failure

**Formaal:** Verificere at HA cluster kan haandtere master node failure.

**Steps:**
```bash
# 1. Identificer en master node (ikke den primare)
MASTER_NODE=$(kubectl get nodes -l node-role.kubernetes.io/master=true -o jsonpath='{.items[1].metadata.name}')

# 2. Stop k3s paa master node
ssh $MASTER_NODE "sudo systemctl stop k3s"

# 3. Vent 2 minutter (etcd failover)
sleep 120

# 4. Verificer cluster status
kubectl get nodes
kubectl get pods -A

# 5. Verificer etcd health
kubectl get --raw /healthz

# 6. Genstart k3s paa master node
ssh $MASTER_NODE "sudo systemctl start k3s"
```

**Expected Result:**
- Cluster fortsaetter med at fungere
- etcd failover sker automatisk
- Ingen data tabt

#### Test 3: Storage Failure

**Formaal:** Verificere at tenants kan genskabes ved storage failure.

**Steps:**
```bash
# 1. Vaelig en test tenant
TENANT="test-storage-failure-01"

# 2. Tag backup
velero backup create $TENANT-storage-test --include-namespaces tenant-$TENANT

# 3. Slet tenant PVCs
kubectl delete pvc -n tenant-$TENANT --all

# 4. Slet tenant
./Scripts/undeploy.sh $TENANT

# 5. Restore tenant
velero restore create --from-backup $TENANT-storage-test \
  --include-namespaces tenant-$TENANT \
  --wait

# 6. Verificer tenant
kubectl get pods -n tenant-$TENANT
./Scripts/cron.sh $TENANT
```

**Expected Result:**
- Tenant genskabes korrekt
- Alle data intakt
- Healthz check OK

### 5.2 DR Test Procedurer

#### Test 4: Full Cluster Restore

**Formaal:** Verificere at hele clusteret kan genskabes fra backup.

**Steps:**
```bash
# 1. Tag full cluster backup
velero backup create full-cluster-test --include-namespaces tenant-*

# 2. Noter backup navn
BACKUP_NAME="full-cluster-test"

# 3. Simuler cluster failure (i test miljo)
# - Stop alle k3s services
# - Slet /var/lib/rancher/k3s/

# 4. Genopret cluster (se afsnit 3.3)

# 5. Restore tenants fra backup
velero restore create full-cluster-restore-test \
  --from-backup $BACKUP_NAME \
  --wait \
  --timeout 30m

# 6. Verificer alle tenants
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  if ! kubectl get pods -n $ns -l app=dolibarr --no-headers | grep -q Running; then
    echo "FAIL: Tenant $ns ikke korer"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done

if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "PASS: Alle tenants korer efter full cluster restore"
else
  echo "FAIL: $FAILED_TENANTS tenants korer ikke"
fi
```

**Expected Result:**
- Cluster genskabes korrekt
- Alle tenants korer
- Ingen data tabt

#### Test 5: etcd Restore

**Formaal:** Verificere at etcd kan genskabes fra snapshot.

**Steps:**
```bash
# 1. Tag etcd snapshot
sudo k3s etcd snapshot save --name test-snapshot

# 2. Noter snapshot navn
SNAPSHOT_NAME="test-snapshot"

# 3. Simuler etcd failure
# - Stop k3s
# - Slet /var/lib/rancher/k3s/server/db/

# 4. Restore etcd
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_NAME

# 5. Start k3s
sudo systemctl start k3s

# 6. Verificer cluster
kubectl get nodes
kubectl get pods -A
```

**Expected Result:**
- etcd genskabes korrekt
- Cluster state intakt
- Alle workloads korer

---

## 6. Runbooks

### 6.1 Cluster Nedetid Runbook

**Symptomer:**
- `kubectl get nodes` viser ingen nodes
- `kubectl get pods -A` fejler
- Alle tenants nedetid

**Diagnose:**
```bash
# Tjek k3s service status
sudo systemctl status k3s

# Tjek k3s logs
sudo journalctl -u k3s -f

# Tjek etcd status
sudo k3s etcdctl endpoint health
```

**Losning:**
1. **Hvis k3s service ikke korer:**
   ```bash
   sudo systemctl restart k3s
   ```

2. **Hvis etcd korrupt:**
   ```bash
   # Restore fra seneste snapshot
   sudo k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<latest>
   ```

3. **Hvis hardware failure:**
   - Fulg proceduren i afsnit 3.3 (Full Cluster Restore)

### 6.2 Tenant Nedetid Runbook

**Symptomer:**
- Enkelt tenant nedetid
- `kubectl get pods -n tenant-12345` viser crashlooping pods

**Diagnose:**
```bash
# Tjek pod logs
kubectl logs -n tenant-12345 <pod-name> --previous

# Tjek pod events
kubectl describe pod -n tenant-12345 <pod-name>

# Tjek pod status
kubectl get pods -n tenant-12345 -o wide

# Tjek healthz
curl -v https://12345.kunder.saasplatform.dk/healthz
```

**Losning:**
1. **Hvis DB pod fejler:**
   ```bash
   # Restart DB pod
   kubectl delete pod -n tenant-12345 -l app.kubernetes.io/component=db
   ```

2. **Hvis app pod fejler:**
   ```bash
   # Restart app pod
   kubectl delete pod -n tenant-12345 -l app=dolibarr
   ```

3. **Hvis PVC problem:**
   ```bash
   # Tjek PVC status
   kubectl get pvc -n tenant-12345
   
   # Hvis PVC stuck i Pending
   kubectl describe pvc -n tenant-12345 <pvc-name>
   ```

4. **Hvis alt fejler:**
   ```bash
   # Restore tenant fra backup
   ./Scripts/restore-tenant.sh 12345
   ```

### 6.3 Backup Failure Runbook

**Symptomer:**
- Velero backup fejler
- `velero backup get` viser Failed status

**Diagnose:**
```bash
# Tjek backup logs
velero backup logs <backup-name>

# Tjek Velero pod logs
kubectl logs -n velero deployment/velero

# Tjek S3 adgang
AWS_ACCESS_KEY_ID=$(cat /etc/saasplatform/velero-credentials | grep aws_access_key_id | cut -d= -f2 | tr -d ' ')
aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com ls s3://saasplatform-backups/ --access-key $AWS_ACCESS_KEY_ID
```

**Losning:**
1. **Hvis S3 credentials udloebet:**
   ```bash
   # Opdater credentials
   velero install --secret-file ./Infrastructure/velero/wasabi-credentials --namespace velero
   ```

2. **Hvis S3 bucket ikke tilgangelig:**
   ```bash
   # Tjek bucket eksistens
   aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com ls s3://saasplatform-backups/
   ```

3. **Hvis Velero pod fejler:**
   ```bash
   # Restart Velero
   kubectl rollout restart deployment velero -n velero
   ```

---

## 7. Vedligeholdelse

### 7.1 Daglig Vedligeholdelse

- **Backup verifikation:** Tjek at alle backups er vellykkede
- **Cluster health:** Tjek at alle nodes er Ready
- **Storage:** Tjek at der er tilstrækkelig storage
- **Certifikater:** Tjek at certifikater ikke udlober

### 7.2 Ugentlig Vedligeholdelse

- **Test restore:** Test restore af en tilfældig tenant
- **k3s opgradering:** Tjek for nye k3s versioner
- **Security updates:** Tjek for nye security patches
- **Performance review:** Review cluster performance

### 7.3 Maenedlig Vedligeholdelse

- **Full DR test:** Udfør full disaster recovery test
- **Capacity planning:** Planlæg fremtidig capacity
- **Cost review:** Review cloud omkostninger
- **Documentation update:** Opdater dokumentation

### 7.4 Kvartalsvis Vedligeholdelse

- **Security audit:** Udfør security audit
- **Architecture review:** Review system arkitektur
- **Compliance check:** Tjek compliance med bogføringslovgivning
- **Team training:** Udfør team training

---

## 8. Ressourcer

- [k3s HA Dokumentation](https://docs.k3s.io/ha-embedded)
- [etcd Dokumentation](https://etcd.io/docs/)
- [Velero Dokumentation](https://velero.io/docs/)
- [Prometheus HA Dokumentation](https://prometheus.io/docs/introduction/overview/)
- [MariaDB Galera Dokumentation](https://galeracluster.com/)
- [ProxySQL Dokumentation](https://proxysql.com/documentation/)
- [Thanos Dokumentation](https://thanos.io/)
- [Disaster Recovery Best Practices](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-considerations/)

---

## 9. Relaterede Dokumentation

- [Fase 1a: Native Deployment](../Fase1a/README.md)
- [Fase 1b: K8s Grundintegration](../Fase1b/README.md)
- [Fase 1c: Livscyklus og Gendannelse](../Fase1c/README.md)
- [Fase 2: Produktionsdrift](../Fase2/README.md)
- [Arkitektur.md](../Arkitektur.md)
- [DECISIONS.md](../DECISIONS.md)
- [Docs/README.md](../README.md)
