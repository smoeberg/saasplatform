# Fase 3 - Testplan: Skalering, HA og Disaster Recovery

## Formaal

Verificere at **skalering, high availability og disaster recovery** fungerer korrekt:
- **Horisontal skalering** af k3s nodes
- **High Availability** for alle kritiske komponenter
- **Disaster Recovery** procedurer
- **RTO < 1 time** og **RPO < 15 minutter**

**Exit-kriterier:** Alle HA/DR tests passeret + RTO/RPO maalt og dokumenteret.

---

## Testmatrix

| ID | Test | Type | Exit-kriterium | Status | Noter | Kritisk |
|----|------|------|----------------|--------|-------|---------|
| 3-01 | Single Node Failure | HA | Cluster fortsaetter med at fungere | [ ] | | Yes |
| 3-02 | Master Node Failure | HA | etcd failover, cluster fortsaetter | [ ] | | Yes |
| 3-03 | Multiple Node Failure | HA | Cluster fortsaetter med nedsat capacity | [ ] | | Yes |
| 3-04 | Traefik HA | HA | Ingress fortsaetter ved pod failure | [ ] | | Yes |
| 3-05 | Prometheus HA | HA | Metrikker tilgangelige ved pod failure | [ ] | | Yes |
| 3-06 | etcd Backup | DR | Backup koret og verificeret | [ ] | | Yes |
| 3-07 | etcd Restore | DR | etcd genskabt, cluster fungerer | [ ] | | Yes |
| 3-08 | Full Cluster Restore | DR | Hele clusteret genskabt | [ ] | | Yes |
| 3-09 | Tenant DR | DR | Enkelt tenant genskabt | [ ] | | Yes |
| 3-10 | Database DR | DR | Database genskabt, data intakt | [ ] | | Yes |
| 3-11 | Storage Failure | DR | Tenant genskabt ved PVC failure | [ ] | | Yes |
| 3-12 | Auto-Scaling | Skalering | HPA og cluster-autoscaler fungerer | [ ] | | No |
| 3-13 | Load Testing | Performance | Cluster haandterer expected load | [ ] | | No |
| 3-14 | RTO Measurement | DR | RTO < 1 time maalt | [ ] | | Yes |
| 3-15 | RPO Measurement | DR | RPO < 15 minutter maalt | [ ] | | Yes |

---

## Forudsætninger

- [ ] Fase 2 er faerdig (produktionsdrift fungerer)
- [ ] k3s cluster koerer med 3+ nodes (1 master + 2 workers)
- [ ] Alle tenants deployet og fungerer
- [ ] Backup infrastructure (Velero + Wasabi S3) fungerer
- [ ] Monitoring stack (Prometheus + Grafana + Loki) fungerer
- [ ] Test tenants deployet

---

## Test Setup

### 1. Test Miljo

```bash
# Forbered test tenants
for i in $(seq 1 5); do
  export SELLYOURSAAS_INSTANCE_NAME="test-ha-0${i}"
  export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://test-ha-0${i}.kunder.saasplatform.dk"
  export SELLYOURSAAS_VERSION="23.0.1"
  ./Scripts/deploy.sh "test-ha-0${i}"
done

# Vent paa alle tenants er klar
sleep 300

# Verificer alle test tenants
for i in $(seq 1 5); do
  ./Scripts/cron.sh "test-ha-0${i}"
done
```

### 2. Backup Forberedelse

```bash
# Tag backup af alle test tenants
velero backup create test-ha-backup --include-namespaces tenant-test-ha-*

# Vent paa backup
velero backup get test-ha-backup --wait

# Verificer backup
velero backup describe test-ha-backup
```

### 3. etcd Backup

```bash
# Tag etcd snapshot
sudo k3s etcd snapshot save --name test-ha-etcd-snapshot

# Verificer snapshot
ls -la /var/lib/rancher/k3s/server/db/snapshots/
```

---

## Test Procedure

---

### Test 3-01: Single Node Failure

**Formaal:** Verificere at cluster fortsaetter med at fungere ved single node failure.

**Steps:**
1. Identificer en worker node
2. Drain node (simuler failure)
3. Vent 5 minutter
4. Verificer cluster status
5. Verificer alle tenants
6. Genoptag node

**Commands:**
```bash
# 1. Identificer en worker node
NODE=$(kubectl get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{.items[0].metadata.name}')
echo "Test node: $NODE"

# 2. Drain node
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
log "info" "Node $NODE drained"

# 3. Vent 5 minutter
sleep 300

# 4. Verificer cluster status
CLUSTER_STATUS=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | tr ' ' '\n' | grep -c "True")
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
if [ "$CLUSTER_STATUS" -ge $((TOTAL_NODES - 1)) ]; then
  echo "PASS: Cluster fortsaetter med at fungere ($CLUSTER_STATUS/$TOTAL_NODES nodes ready)"
else
  echo "FAIL: Cluster ikke fuldt funktionel"
fi

# 5. Verificer alle tenants
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  if ! kubectl get pods -n $ns -l app=dolibarr --no-headers | grep -q Running; then
    echo "FAIL: Tenant $ns ikke korer"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done
if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "PASS: Alle tenants korer"
else
  echo "FAIL: $FAILED_TENANTS tenants korer ikke"
fi

# 6. Genoptag node
kubectl uncordon $NODE
sleep 30
kubectl get nodes
```

**Expected Result:**
- Cluster fortsaetter med at fungere (alle eller alle undtagen 1 node ready)
- Alle tenants korer
- Ingen data tabt

**Cleanup:**
```bash
# Ingen cleanup nødvendig
```

---

### Test 3-02: Master Node Failure

**Formaal:** Verificere at HA cluster kan haandtere master node failure.

**Steps:**
1. Identificer en master node (ikke den primære)
2. Stop k3s paa master node
3. Vent 2 minutter (etcd failover)
4. Verificer cluster status
5. Verificer etcd health
6. Genstart k3s paa master node

**Commands:**
```bash
# 1. Identificer en master node (ikke den primære)
MASTER_NODE=$(kubectl get nodes -l node-role.kubernetes.io/master=true -o jsonpath='{.items[1].metadata.name}')
echo "Test master node: $MASTER_NODE"

# 2. Stop k3s
ssh $MASTER_NODE "sudo systemctl stop k3s"
log "info" "k3s stopped paa $MASTER_NODE"

# 3. Vent 2 minutter
sleep 120

# 4. Verificer cluster status
if kubectl get nodes >/dev/null 2>&1; then
  echo "PASS: Cluster fortsaetter med at fungere"
else
  echo "FAIL: Cluster ikke tilgangelig"
fi

# 5. Verificer etcd health
ETCD_HEALTH=$(kubectl get --raw /healthz 2>/dev/null | grep -c "ok" || echo "0")
if [ "$ETCD_HEALTH" -ge 1 ]; then
  echo "PASS: etcd health OK"
else
  echo "FAIL: etcd health problem"
fi

# 6. Genstart k3s
ssh $MASTER_NODE "sudo systemctl start k3s"
sleep 30
kubectl get nodes
```

**Expected Result:**
- Cluster fortsaetter med at fungere
- etcd failover sker automatisk
- Ingen data tabt

**Cleanup:**
```bash
# Ingen cleanup nødvendig
```

**Note:** Denne test kræver multi-master k3s HA setup.

---

### Test 3-03: Multiple Node Failure

**Formaal:** Verificere at cluster kan haandtere multiple node failures.

**Steps:**
1. Identificer 2 worker nodes
2. Drain begge nodes
3. Vent 5 minutter
4. Verificer cluster status
5. Verificer tenants
6. Genoptag nodes

**Commands:**
```bash
# 1. Identificer 2 worker nodes
NODE1=$(kubectl get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{.items[0].metadata.name}')
NODE2=$(kubectl get nodes -l node-role.kubernetes.io/worker=true -o jsonpath='{.items[1].metadata.name}')
echo "Test nodes: $NODE1, $NODE2"

# 2. Drain nodes
kubectl drain $NODE1 --ignore-daemonsets --delete-emptydir-data
kubectl drain $NODE2 --ignore-daemonsets --delete-emptydir-data
log "info" "Nodes $NODE1, $NODE2 drained"

# 3. Vent 5 minutter
sleep 300

# 4. Verificer cluster status
READY_NODES=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l || echo "0")
if [ "$READY_NODES" -ge 1 ]; then
  echo "PASS: Cluster fortsaetter med at fungere ($READY_NODES/$TOTAL_NODES nodes ready)"
else
  echo "FAIL: Cluster ikke funktionel"
fi

# 5. Verificer tenants
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  if ! kubectl get pods -n $ns -l app=dolibarr --no-headers | grep -q Running; then
    echo "FAIL: Tenant $ns ikke korer"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done
if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "PASS: Alle tenants korer"
else
  echo "FAIL: $FAILED_TENANTS tenants korer ikke"
fi

# 6. Genoptag nodes
kubectl uncordon $NODE1
kubectl uncordon $NODE2
sleep 60
kubectl get nodes
```

**Expected Result:**
- Cluster fortsaetter med at fungere (mindst 1 node ready)
- Tenants kan vaere nedsat, men ingen data tabt

**Cleanup:**
```bash
# Ingen cleanup nødvendig
```

---

### Test 3-04: Traefik HA

**Formaal:** Verificere at Traefik HA fungerer (Ingress fortsaetter ved pod failure).

**Steps:**
1. Identificer Traefik pods
2. Slet en Traefik pod
3. Vent paa ny pod
4. Verificer Ingress
5. Verificer tenants

**Commands:**
```bash
# 1. Identificer Traefik pods
TRAEFIK_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].metadata.name}')
echo "Traefik pods: $TRAEFIK_PODS"

# 2. Slet en Traefik pod
TRAEFIK_POD=$(echo $TRAEFIK_PODS | awk '{print $1}')
kubectl delete pod -n kube-system $TRAEFIK_POD
log "info" "Traefik pod $TRAEFIK_POD slettet"

# 3. Vent paa ny pod
sleep 30
NEW_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].metadata.name}')
if [ "$NEW_PODS" != "$TRAEFIK_PODS" ]; then
  echo "PASS: Ny Traefik pod oprettet"
else
  echo "FAIL: Ny Traefik pod ikke oprettet"
fi

# 4. Verificer Ingress
INGRESS_STATUS=$(kubectl get ingress -A -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}' | head -1)
if [ -n "$INGRESS_STATUS" ]; then
  echo "PASS: Ingress tilgangelig"
else
  echo "FAIL: Ingress ikke tilgangelig"
fi

# 5. Verificer tenants
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  contract=${ns#tenant-}
  if ! curl -fsS -o /dev/null -m 5 "https://${contract}.kunder.saasplatform.dk/healthz" &>/dev/null; then
    echo "FAIL: Tenant $contract healthz fejler"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done
if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "PASS: Alle tenants tilgangelige"
else
  echo "FAIL: $FAILED_TENANTS tenants ikke tilgangelige"
fi
```

**Expected Result:**
- Ny Traefik pod oprettet automatisk
- Ingress fortsaetter med at fungere
- Alle tenants tilgangelige

**Cleanup:**
```bash
# Ingen cleanup nødvendig
```

---

### Test 3-05: Prometheus HA

**Formaal:** Verificere at Prometheus HA fungerer (metrikker tilgangelige ved pod failure).

**Steps:**
1. Port-forward til Prometheus
2. Identificer Prometheus pods
3. Slet en Prometheus pod
4. Vent paa ny pod
5. Verificer metrikker

**Commands:**
```bash
# 1. Port-forward til Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
PROM_PID=$!
sleep 2

# 2. Identificer Prometheus pods
PROM_PODS=$(kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[*].metadata.name}')
echo "Prometheus pods: $PROM_PODS"

# 3. Slet en Prometheus pod
PROM_POD=$(echo $PROM_PODS | awk '{print $1}')
kubectl delete pod -n monitoring $PROM_POD
log "info" "Prometheus pod $PROM_POD slettet"

# 4. Vent paa ny pod
sleep 60
NEW_PODS=$(kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[*].metadata.name}')
if [ "$NEW_PODS" != "$PROM_PODS" ]; then
  echo "PASS: Ny Prometheus pod oprettet"
else
  echo "FAIL: Ny Prometheus pod ikke oprettet"
fi

# 5. Verificer metrikker
TARGETS_STATUS=$(curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[].health' | grep -c "up" || echo "0")
if [ "$TARGETS_STATUS" -gt 0 ]; then
  echo "PASS: Metrikker tilgangelige"
else
  echo "FAIL: Metrikker ikke tilgangelige"
fi

# Cleanup
kill $PROM_PID
```

**Expected Result:**
- Ny Prometheus pod oprettet automatisk
- Metrikker fortsaetter med at blive indsamlet

**Cleanup:**
```bash
# Ingen cleanup nødvendig
```

---

### Test 3-06: etcd Backup

**Formaal:** Verificere at etcd backup fungerer.

**Steps:**
1. Tag etcd snapshot
2. Verificer snapshot
3. Tjek snapshot stoerrelse
4. Upload til S3 (valgfrit)

**Commands:**
```bash
# 1. Tag etcd snapshot
SNAPSHOT_NAME="test-etcd-$(date +%Y%m%d%H%M%S)"
sudo k3s etcd snapshot save --name $SNAPSHOT_NAME
log "info" "etcd snapshot taget: $SNAPSHOT_NAME"

# 2. Verificer snapshot
if [ -f "/var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_NAME" ]; then
  echo "PASS: Snapshot fil eksisterer"
else
  echo "FAIL: Snapshot fil ikke fundet"
fi

# 3. Tjek snapshot stoerrelse
SNAPSHOT_SIZE=$(stat -c%s "/var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_NAME" 2>/dev/null || echo "0")
if [ "$SNAPSHOT_SIZE" -gt 1000 ]; then
  echo "PASS: Snapshot stoerrelse OK ($SNAPSHOT_SIZE bytes)"
else
  echo "FAIL: Snapshot stoerrelse for lille"
fi

# 4. Upload til S3 (valgfrit)
if [[ -n "$S3_ENDPOINT" && -n "$S3_BUCKET" ]]; then
  aws s3 --endpoint-url=$S3_ENDPOINT cp \
    /var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_NAME \
    s3://$S3_BUCKET/etcd/$SNAPSHOT_NAME
  if [ $? -eq 0 ]; then
    echo "PASS: Snapshot uploadet til S3"
  else
    echo "WARN: Snapshot upload fejlede"
  fi
fi
```

**Expected Result:**
- Snapshot fil eksisterer
- Snapshot stoerrelse > 1000 bytes
- Snapshot uploadet til S3 (hvis konfigureret)

**Cleanup:**
```bash
# Slet snapshot
sudo rm -f /var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_NAME
```

---

### Test 3-07: etcd Restore

**Formaal:** Verificere at etcd kan genskabes fra snapshot.

**Steps:**
1. Tag etcd snapshot
2. Simuler etcd failure (i test miljo)
3. Restore etcd
4. Verificer cluster

**Commands:**
```bash
# 1. Tag etcd snapshot
SNAPSHOT_NAME="test-etcd-restore-$(date +%Y%m%d%H%M%S)"
sudo k3s etcd snapshot save --name $SNAPSHOT_NAME
log "info" "etcd snapshot taget: $SNAPSHOT_NAME"

# 2. Simuler etcd failure (STOP HER i produktionsmiljo!)
# Kun udfør i test miljo:
echo "WARNING: Denne test skal kun udføres i test miljø!"
echo "For at fortsætte, indtast 'TEST_MILJO'"
read -r CONFIRM
if [ "$CONFIRM" != "TEST_MILJO" ]; then
  echo "Test annulleret"
  exit 0
fi

# Stop k3s (simuler failure)
sudo systemctl stop k3s

# 3. Restore etcd
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_NAME &

# Vent paa k3s start
sleep 60

# 4. Verificer cluster
if kubectl get nodes >/dev/null 2>&1; then
  echo "PASS: Cluster genskabt"
else
  echo "FAIL: Cluster ikke genskabt"
fi

# Verificer etcd health
ETCD_HEALTH=$(kubectl get --raw /healthz 2>/dev/null | grep -c "ok" || echo "0")
if [ "$ETCD_HEALTH" -ge 1 ]; then
  echo "PASS: etcd health OK"
else
  echo "FAIL: etcd health problem"
fi
```

**Expected Result:**
- etcd genskabt korrekt
- Cluster state intakt
- Alle workloads korer

**Cleanup:**
```bash
# Slet snapshot
sudo rm -f /var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_NAME
```

---

### Test 3-08: Full Cluster Restore

**Formaal:** Verificere at hele clusteret kan genskabes fra backup.

**Steps:**
1. Tag full cluster backup
2. Noter backup navn
3. Simuler cluster failure (i test miljo)
4. Genopret cluster
5. Restore tenants
6. Verificer alle tenants

**Commands:**
```bash
# 1. Tag full cluster backup
BACKUP_NAME="test-full-restore-$(date +%Y%m%d%H%M%S)"
velero backup create $BACKUP_NAME --include-namespaces tenant-test-ha-*
log "info" "Backup taget: $BACKUP_NAME"

# Vent paa backup
velero backup get $BACKUP_NAME --wait

# 2. Noter backup navn
echo "Backup navn: $BACKUP_NAME"

# 3. Simuler cluster failure (STOP HER i produktionsmiljo!)
echo "WARNING: Denne test skal kun udføres i test miljø!"
echo "For at fortsætte, indtast 'TEST_MILJO'"
read -r CONFIRM
if [ "$CONFIRM" != "TEST_MILJO" ]; then
  echo "Test annulleret"
  exit 0
fi

# I test miljø: stop k3s, slet data, genstart
# (Specifikke kommandoer afhaenger af test setup)

# 4. Genopret cluster (se README.md afsnit 3.3)
# - Installer k3s paa nye servere
# - Restore etcd
# - Deploy infrastructure

# 5. Restore tenants
velero restore create test-full-restore-$(date +%Y%m%d%H%M%S) \
  --from-backup $BACKUP_NAME \
  --wait \
  --timeout 30m

# 6. Verificer alle tenants
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-test-ha-'); do
  if ! kubectl get pods -n $ns -l app=dolibarr --no-headers | grep -q Running; then
    echo "FAIL: Tenant $ns ikke korer"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done

if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "PASS: Alle test tenants korer"
else
  echo "FAIL: $FAILED_TENANTS test tenants korer ikke"
fi
```

**Expected Result:**
- Cluster genskabt korrekt
- Alle tenants korer
- Ingen data tabt

**Cleanup:**
```bash
# Slet backup
velero backup delete $BACKUP_NAME --confirm
```

---

### Test 3-09: Tenant DR

**Formaal:** Verificere at enkelt tenant kan genskabes ved DR.

**Steps:**
1. Tag tenant backup
2. Slet tenant
3. Restore tenant
4. Verificer tenant

**Commands:**
```bash
# 1. Tag tenant backup
TENANT="test-ha-01"
velero backup create $TENANT-dr-test --include-namespaces tenant-$TENANT
log "info" "Tenant backup taget"

# Vent paa backup
velero backup get $TENANT-dr-test --wait

# 2. Slet tenant
./Scripts/undeploy.sh $TENANT
sleep 10

# 3. Restore tenant
velero restore create $TENANT-dr-restore --from-backup $TENANT-dr-test \
  --include-namespaces tenant-$TENANT \
  --wait \
  --timeout 10m

# 4. Verificer tenant
if kubectl get ns tenant-$TENANT >/dev/null 2>&1; then
  echo "PASS: Tenant namespace genskabt"
else
  echo "FAIL: Tenant namespace ikke genskabt"
fi

# Verificer pods
POD_COUNT=$(kubectl get pods -n tenant-$TENANT --no-headers | grep -c Running || echo "0")
if [ "$POD_COUNT" -ge 2 ]; then
  echo "PASS: Tenant pods korer"
else
  echo "FAIL: Tenant pods korer ikke (count: $POD_COUNT)"
fi

# Verificer healthz
if ./Scripts/cron.sh $TENANT; then
  echo "PASS: Tenant healthz OK"
else
  echo "FAIL: Tenant healthz fejler"
fi
```

**Expected Result:**
- Tenant genskabt korrekt
- Alle pods korer
- Healthz OK

**Cleanup:**
```bash
# Slet backup
velero backup delete $TENANT-dr-test --confirm
velero restore delete $TENANT-dr-restore --confirm
```

---

### Test 3-10: Database DR

**Formaal:** Verificere at database kan genskabes ved DR.

**Steps:**
1. Tag DB dump
2. Simuler DB korruption
3. Restore DB
4. Verificer DB

**Commands:**
```bash
# 1. Tag DB dump (via beforeundeploy.sh)
TENANT="test-ha-02"
./Scripts/beforeundeploy.sh $TENANT

# Find DB dump fil
DUMP_FILE=$(ls -t /var/backups/saasplatform/pre-undeploy/tenant-$TENANT-*.sql.gz | head -1)
if [ -n "$DUMP_FILE" ]; then
  echo "PASS: DB dump taget"
else
  echo "FAIL: DB dump ikke fundet"
fi

# 2. Simuler DB korruption (STOP HER i produktionsmiljo!)
echo "WARNING: Denne test skal kun udføres i test miljø!"
echo "For at fortsætte, indtast 'TEST_MILJO'"
read -r CONFIRM
if [ "$CONFIRM" != "TEST_MILJO" ]; then
  echo "Test annulleret"
  exit 0
fi

# Slet MariaDB data
kubectl delete pvc -n tenant-$TENANT --all
kubectl delete statefulset mariadb -n tenant-$TENANT

# 3. Restore DB
# Redeploy tenant med suspended=true
helm upgrade --install tenant-$TENANT Helm/erp-tenant \
  -n tenant-$TENANT \
  -f $VALUES_DIR/tenant-$TENANT.yaml \
  --set suspended=true \
  --wait --timeout 5m

# Vent paa MariaDB pod
sleep 60

# Restore DB dump
kubectl exec -n tenant-$TENANT pod/mariadb-0 -- \
  sh -c "zcat /tmp/restore.sql.gz | mysql -u \$MARIADB_USER -p\$MARIADB_PASSWORD dolibarr" || true

# Unsuspend tenant
helm upgrade tenant-$TENANT Helm/erp-tenant \
  -n tenant-$TENANT \
  -f $VALUES_DIR/tenant-$TENANT.yaml \
  --set suspended=false \
  --wait --timeout 5m

# 4. Verificer DB
if ./Scripts/cron.sh $TENANT; then
  echo "PASS: DB restore vellykket"
else
  echo "FAIL: DB restore fejlede"
fi
```

**Expected Result:**
- Database genskabt korrekt
- Tenant fungerer
- Data intakt

**Cleanup:**
```bash
# Ingen cleanup nødvendig
```

---

### Test 3-11: Storage Failure

**Formaal:** Verificere at tenant kan genskabes ved storage failure.

**Steps:**
1. Tag tenant backup
2. Slet tenant PVCs
3. Slet tenant
4. Restore tenant
5. Verificer tenant

**Commands:**
```bash
# 1. Tag tenant backup
TENANT="test-ha-03"
velero backup create $TENANT-storage-test --include-namespaces tenant-$TENANT
velero backup get $TENANT-storage-test --wait

# 2. Slet tenant PVCs
kubectl delete pvc -n tenant-$TENANT --all
log "info" "PVCs slettet for tenant $TENANT"

# 3. Slet tenant
./Scripts/undeploy.sh $TENANT
sleep 10

# 4. Restore tenant
velero restore create $TENANT-storage-restore --from-backup $TENANT-storage-test \
  --include-namespaces tenant-$TENANT \
  --wait \
  --timeout 10m

# 5. Verificer tenant
if ./Scripts/cron.sh $TENANT; then
  echo "PASS: Tenant genskabt efter storage failure"
else
  echo "FAIL: Tenant ikke genskabt"
fi
```

**Expected Result:**
- Tenant genskabt korrekt
- Alle data intakt

**Cleanup:**
```bash
# Slet backup
velero backup delete $TENANT-storage-test --confirm
velero restore delete $TENANT-storage-restore --confirm
```

---

### Test 3-12: Auto-Scaling

**Formaal:** Verificere at auto-scaling fungerer.

**Steps:**
1. Enable HPA for test tenant
2. Skab load paa tenant
3. Vent paa scaling
4. Verificer replicas

**Commands:**
```bash
# 1. Enable HPA for test tenant
kubectl apply -f - << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dolibarr
  namespace: tenant-test-ha-04
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: dolibarr
  minReplicas: 1
  maxReplicas: 2
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
EOF

# 2. Skab load paa tenant
kubectl run load-generator --image=busybox -n tenant-test-ha-04 --restart=Never -- \
  while true; do curl -s http://dolibarr:80 >/dev/null; sleep 0.1; done

# 3. Vent paa scaling (5 minutter)
sleep 300

# 4. Verificer replicas
REPLICAS=$(kubectl get hpa -n tenant-test-ha-04 dolibarr -o jsonpath='{.status.currentReplicas}')
if [ "$REPLICAS" -gt 1 ]; then
  echo "PASS: HPA scaled til $REPLICAS replicas"
else
  echo "FAIL: HPA ikke scaled (replicas: $REPLICAS)"
fi

# Cleanup
kubectl delete hpa -n tenant-test-ha-04 dolibarr
kubectl delete pod -n tenant-test-ha-04 load-generator
```

**Expected Result:**
- HPA scaler tenant til 2+ replicas
- Load håndteret korrekt

**Note:** HPA er **deaktiveret som default** pga. ReadWriteOnce PVC begrensning.

---

### Test 3-13: Load Testing

**Formaal:** Verificere at cluster kan håndtere expected load.

**Steps:**
1. Installer load testing tool (k6)
2. Konfigurer load test
3. Kør load test
4. Monitor cluster
5. Verificer performance

**Commands:**
```bash
# 1. Installer k6
sudo apt install -y k6

# 2. Konfigurer load test
cat > /tmp/load-test.js << 'EOF'
import http from 'k6/http';
import { check } from 'k6';

export default function () {
  const res = http.get('https://test-ha-05.kunder.saasplatform.dk/healthz');
  check(res, {
    'status is 200': (r) => r.status === 200,
  });
}
EOF

# 3. Kør load test (100 RPS i 5 minutter)
k6 run --vus 100 --duration 300s /tmp/load-test.js

# 4. Monitor cluster under test
# I et andet terminal:
watch -n 5 "kubectl top nodes; kubectl top pods -A"

# 5. Verificer performance
# Tjek at:
# - Alle nodes har CPU < 80%
# - Alle pods korer
# - Ingen errors i k6 output
```

**Expected Result:**
- Cluster håndterer 100 RPS
- Ingen nodes overloaded
- Ingen pods fejler

**Cleanup:**
```bash
rm /tmp/load-test.js
```

---

### Test 3-14: RTO Measurement

**Formaal:** Maale Recovery Time Objective (RTO) for tenant restore.

**Steps:**
1. Tag backup af tenant
2. Noter start tid
3. Slet tenant
4. Restore tenant
5. Noter slut tid
6. Beregn RTO

**Commands:**
```bash
# 1. Tag backup
TENANT="test-ha-01"
velero backup create $TENANT-rto-test --include-namespaces tenant-$TENANT
velero backup get $TENANT-rto-test --wait

# 2. Noter start tid
START_TIME=$(date +%s)
echo "Start tid: $START_TIME"

# 3. Slet tenant
./Scripts/undeploy.sh $TENANT

# 4. Restore tenant
velero restore create $TENANT-rto-restore --from-backup $TENANT-rto-test \
  --include-namespaces tenant-$TENANT \
  --wait

# 5. Noter slut tid
END_TIME=$(date +%s)
echo "Slut tid: $END_TIME"

# 6. Beregn RTO
RTO=$((END_TIME - START_TIME))
RTO_MINUTES=$((RTO / 60))
echo "RTO: ${RTO} sekunder (${RTO_MINUTES} minutter)"

if [ "$RTO" -lt 3600 ]; then  # < 1 time
  echo "PASS: RTO < 1 time (${RTO} sekunder)"
else
  echo "FAIL: RTO >= 1 time (${RTO} sekunder)"
fi
```

**Expected Result:**
- RTO < 3600 sekunder (1 time)

**Cleanup:**
```bash
# Slet backup
velero backup delete $TENANT-rto-test --confirm
velero restore delete $TENANT-rto-restore --confirm
```

---

### Test 3-15: RPO Measurement

**Formaal:** Maale Recovery Point Objective (RPO) for backup.

**Steps:**
1. Tag backup af tenant
2. Noter backup tid
3. Lav aendringer i tenant
4. Noter aendringstid
5. Beregn RPO

**Commands:**
```bash
# 1. Tag backup
TENANT="test-ha-02"
velero backup create $TENANT-rpo-test --include-namespaces tenant-$TENANT
velero backup get $TENANT-rpo-test --wait

# 2. Noter backup tid
BACKUP_TIME=$(velero backup get $TENANT-rpo-test -o jsonpath='{.status.completionTimestamp}')
BACKUP_EPOCH=$(date -d "$BACKUP_TIME" +%s)
echo "Backup tid: $BACKUP_TIME ($BACKUP_EPOCH)"

# 3. Lav aendringer i tenant (opdater config)
# Simuler data aendring
kubectl exec -n tenant-$TENANT pod/dolibarr-0 -- \
  touch /var/www/dolibarr/documents/test-rpo-$(date +%s)

# 4. Noter aendringstid
CHANGE_TIME=$(date +%s)
echo "Aendringstid: $CHANGE_TIME"

# 5. Beregn RPO
RPO=$((CHANGE_TIME - BACKUP_EPOCH))
RPO_MINUTES=$((RPO / 60))
echo "RPO: ${RPO} sekunder (${RPO_MINUTES} minutter)"

if [ "$RPO" -lt 900 ]; then  # < 15 minutter
  echo "PASS: RPO < 15 minutter (${RPO} sekunder)"
else
  echo "FAIL: RPO >= 15 minutter (${RPO} sekunder)"
fi
```

**Expected Result:**
- RPO < 900 sekunder (15 minutter)

**Cleanup:**
```bash
# Slet backup
velero backup delete $TENANT-rpo-test --confirm
```

---

## Test Cleanup

```bash
# Slet alle test tenants
for i in $(seq 1 5); do
  ./Scripts/undeploy.sh "test-ha-0${i}"
done

# Slet alle test backups
velero backup delete --all --confirm 2>/dev/null || true
velero restore delete --all --confirm 2>/dev/null || true

# Slet test snapshots
sudo rm -f /var/lib/rancher/k3s/server/db/snapshots/test-*.snapshot 2>/dev/null || true

# Slet test filer
rm -f /tmp/load-test.js /tmp/k6-output.txt
```

---

## Exit Kriterier

### Minimum (for at gaa videre til fase 4)

- [ ] **3-01** Single Node Failure fungerer
- [ ] **3-02** Master Node Failure fungerer (hvis HA setup)
- [ ] **3-06** etcd Backup fungerer
- [ ] **3-07** etcd Restore fungerer
- [ ] **3-08** Full Cluster Restore fungerer
- [ ] **3-09** Tenant DR fungerer
- [ ] **3-10** Database DR fungerer
- [ ] **3-14** RTO < 1 time maalt
- [ ] **3-15** RPO < 15 minutter maalt

### Fuldt (anbefalet)

- [ ] Alle 15 tests bestaaet
- [ ] Alle HA tests passeret
- [ ] Alle DR tests passeret
- [ ] RTO og RPO dokumenteret
- [ ] Runbooks testet
- [ ] Team training udfort

---

## Ressourcer

- [Fase 3 README](README.md)
- [Fase 3 Installationstjekliste](Installationstjekliste.md)
- [Disaster Recovery Dokumentation](Disaster-Recovery.md)
- [Arkitektur.md](../Arkitektur.md)
- [k6 Dokumentation](https://k6.io/docs/)
- [k3s HA Dokumentation](https://docs.k3s.io/ha-embedded)
- [Velero Dokumentation](https://velero.io/docs/)
