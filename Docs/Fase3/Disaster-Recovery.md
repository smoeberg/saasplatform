# Fase 3 - Disaster Recovery Runbook

## Formaal

Dette dokument indeholder **komplette disaster recovery procedurer** for saasplatform, inklusive:
- **Runbooks** for alle DR scenarier
- **Step-by-step guides** for recovery
- **Kontaktinformation** og eskalationsveje
- **RTO/RPO garantier** og maalinger
- **Post-mortem templates** for incident analyse

---

## DR Overview

### DR Scenarier

| Scenarie | Beskrivelse | RTO | RPO | Prioritet | Frekvens |
|----------|-------------|-----|-----|-----------|----------|
| **SC-01** | Single Node Failure | < 10 min | 0 | Høj | Hyppig |
| **SC-02** | Multiple Node Failure | < 30 min | 0 | Høj | Sjælden |
| **SC-03** | Master Node Failure | < 15 min | 0 | Kritisk | Sjælden |
| **SC-04** | Full Cluster Outage | < 1 time | < 15 min | Kritisk | Meget sjælden |
| **SC-05** | Storage Failure | < 1 time | < 15 min | Høj | Sjælden |
| **SC-06** | Database Korruption | < 1 time | < 15 min | Kritisk | Sjælden |
| **SC-07** | Network Outage | < 30 min | 0 | Høj | Sjælden |
| **SC-08** | DNS Outage | < 1 time | 0 | Medium | Sjælden |
| **SC-09** | Certificate Expiration | < 1 time | 0 | Medium | Hyppig |

### DR Team

| Rolle | Navn | Telefon | Email | Slack | PagerDuty |
|-------|------|---------|-------|-------|-----------|
| **Primary On-Call** | | +45 XX XX XX XX | oncall@saasplatform.dk | @oncall | [Link](#) |
| **Secondary On-Call** | | +45 XX XX XX XX | oncall2@saasplatform.dk | @oncall2 | [Link](#) |
| **Database Specialist** | | +45 XX XX XX XX | db@saasplatform.dk | @db-team | [Link](#) |
| **Infrastructure Lead** | | +45 XX XX XX XX | infra@saasplatform.dk | @infra | [Link](#) |
| **Application Lead** | | +45 XX XX XX XX | app@saasplatform.dk | @app | [Link](#) |

### Eskalationsveje

```
┌─────────────────────────────────────────────────────────────────┐
│                        INCIDENT DETECTED                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Level 1: Primary On-Call                       │
│  - Triage incident (15 min)                                    │
│  - Attempt initial recovery                                    │
│  - Document findings                                          │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│   Resolved           │ │  Not Resolved       │ │  Not Resolved       │
│   (Close Incident)   │ │  After 30 min       │ │  After 1 hour       │
└─────────────────────┘ └─────────────────────┘ └─────────────────────┘
                              │                       │
                              ▼                       ▼
                    ┌─────────────────────┐ ┌─────────────────────┐
                    │ Level 2: Secondary   │ │ Level 3: Team Lead  │
                    │ On-Call             │ │ + All Specialists   │
                    │ - Deep dive         │ │ - Full team         │
                    │ - Advanced recovery  │ │ - Vendor escalation │
                    └─────────────────────┘ └─────────────────────┘
                              │                       │
                              └───────────────────────┼───────────────────────┘
                                                      ▼
                                             ┌─────────────────────────┐
                                             │ Level 4: Management      │
                                             │ - Business impact       │
                                             │ - Customer communication │
                                             │ - External escalation   │
                                             └─────────────────────────┘
```

---

## DR Procedurer

---

### SC-01: Single Node Failure

**Scenarie:** En enkelt k3s node (worker eller master) fejler.

**Symptomer:**
- `kubectl get nodes` viser en node med `NotReady` status
- Workloads paa den paagældende node kan vaere nede
- `kubectl describe node <node>` viser errors

**Impact:**
- **Hoj:** Tenants paa den fejlede node kan vaere nede
- **Data tab:** Ingen (hvis node korrekt draines)

**RTO:** < 10 minutter
**RPO:** 0

---

#### Detection

**Automatisk detection (Prometheus alerts):**
- `ClusterNodeDown` alert triggeres
- Alert sendes til Slack og PagerDuty

**Manuel detection:**
```bash
# Tjek node status
kubectl get nodes

# Tjek node details
kubectl describe node <node-name>

# Tjek node logs
sudo journalctl -u k3s -f  # Paa den paagældende node
```

---

#### Immediate Actions

1. **Identificer den fejlede node:**
   ```bash
   FAILED_NODE=$(kubectl get nodes -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")].metadata.name}')
   echo "Fejlet node: $FAILED_NODE"
   ```

2. **Tjek node type:**
   ```bash
   NODE_TYPE=$(kubectl get node $FAILED_NODE -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}')
   if [ "$NODE_TYPE" == "true" ]; then
     echo "Master node failure - se SC-03"
     exit 1
   fi
   echo "Worker node failure"
   ```

3. **Drain node (hvis den ikke allerede er drainet):**
   ```bash
   kubectl drain $FAILED_NODE --ignore-daemonsets --delete-emptydir-data --force
   ```

---

#### Recovery Steps

**Option A: Genstart k3s service (hvis node er reachable)**
```bash
# Paa den fejlede node
ssh $FAILED_NODE

# Genstart k3s
sudo systemctl restart k3s

# Vent 2 minutter
sleep 120

# Tjek status
kubectl get nodes
```

**Option B: Reboot node (hvis genstart ikke virker)**
```bash
# Paa den fejlede node
sudo reboot

# Vent 5 minutter
sleep 300

# Tjek status
kubectl get nodes
```

**Option C: Erstat node (hvis hardware failure)**
```bash
# 1. Fjern node fra cluster
kubectl delete node $FAILED_NODE

# 2. Forbered ny node (samme spec)
# 3. Installer k3s agent
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<master-ip>:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent

# 4. Verificer
kubectl get nodes
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek at node er Ready
kubectl get nodes

# 2. Tjek at alle pods er scheduled
kubectl get pods -A -o wide | grep $FAILED_NODE

# 3. Tjek at alle tenants fungerer
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  if ! kubectl get pods -n $ns -l app=dolibarr --no-headers | grep -q Running; then
    echo "WARNING: Tenant $ns ikke korer"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done

if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "SUCCESS: Alle tenants fungerer"
else
  echo "WARNING: $FAILED_TENANTS tenants skal undersoges"
fi

# 4. Tjek healthz for alle tenants
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  contract=${ns#tenant-}
  if ! curl -fsS -o /dev/null -m 5 "https://${contract}.kunder.saasplatform.dk/healthz" &>/dev/null; then
    echo "WARNING: Healthz fejler for $contract"
  fi
done

# 5. Uncordon node (hvis den var drainet)
kubectl uncordon $FAILED_NODE
```

---

#### Communication

**Internal:**
- Slack: `@oncall Node failure resolved - $FAILED_NODE`
- Incident log: Opdater med recovery steps

**External (hvis relevant):**
- Status page: Opdater hvis der var customer impact

---

---

### SC-02: Multiple Node Failure

**Scenarie:** 2+ k3s nodes fejler samtidigt.

**Symptomer:**
- `kubectl get nodes` viser multiple nodes med `NotReady` status
- Workloads kan vaere nede
- Cluster capacity reduceret

**Impact:**
- **Hoj:** Flere tenants kan vaere nede
- **Data tab:** Ingen (hvis nodes korrekt draines)

**RTO:** < 30 minutter
**RPO:** 0

---

#### Detection

**Automatisk detection:**
- `HighNodeFailure` alert triggeres
- `ClusterNodeDown` alerts for multiple nodes

**Manuel detection:**
```bash
# Tjek node status
kubectl get nodes

# Tjek antal ready nodes
READY_COUNT=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")
TOTAL_COUNT=$(kubectl get nodes --no-headers | wc -l || echo "0")
echo "Ready nodes: $READY_COUNT/$TOTAL_COUNT"

if [ "$READY_COUNT" -lt $((TOTAL_COUNT - 1)) ]; then
  echo "WARNING: Multiple nodes down"
fi
```

---

#### Immediate Actions

1. **Identificer alle fejlede nodes:**
   ```bash
   FAILED_NODES=$(kubectl get nodes -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")].metadata.name}' | tr ' ' '\n')
   echo "Fejlede nodes:"
   echo "$FAILED_NODES"
   ```

2. **Drain alle fejlede nodes:**
   ```bash
   for node in $FAILED_NODES; do
     kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force
   done
   ```

---

#### Recovery Steps

**For hver fejlet node:**
1. Foelg proceduren fra **SC-01: Single Node Failure**

**Hvis mere end 50% af nodes er nede:**
1. **Prioriter master nodes** (se SC-03)
2. **Prioriter nodes med flest tenants**
3. **Skaler op** (tilfoej nye nodes) for at genoprette capacity

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek at alle nodes er Ready
kubectl get nodes

# 2. Tjek at alle pods er scheduled
kubectl get pods -A -o wide

# 3. Tjek at alle tenants fungerer
./Scripts/cron.sh test-all-tenants

# 4. Tjek cluster capacity
kubectl describe nodes | grep -A 3 "Allocated resources"
```

---

---

### SC-03: Master Node Failure

**Scenarie:** En master node i HA cluster fejler.

**Symptomer:**
- `kubectl get nodes` viser en master node med `NotReady` status
- etcd kan vaere i degraded state
- Cluster API kan vaere langsomt

**Impact:**
- **Kritisk:** Cluster kan blive ustabilt
- **Data tab:** Ingen (etcd replikeret)

**RTO:** < 15 minutter
**RPO:** 0

---

#### Detection

**Automatisk detection:**
- `etcdNoLeader` alert kan triggeres
- `ClusterNodeDown` alert for master node

**Manuel detection:**
```bash
# Tjek master nodes
kubectl get nodes -l node-role.kubernetes.io/master=true

# Tjek etcd health
kubectl get --raw /healthz

# Tjek etcd members
sudo k3s etcdctl member list
```

---

#### Immediate Actions

1. **Identificer den fejlede master node:**
   ```bash
   FAILED_MASTER=$(kubectl get nodes -l node-role.kubernetes.io/master=true -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")].metadata.name}')
   echo "Fejlet master: $FAILED_MASTER"
   ```

2. **Tjek om det er den primære master:**
   ```bash
   # Paa en sund master node
   PRIMARY_MASTER=$(sudo k3s etcdctl endpoint status --endpoints=https://127.0.0.1:2379 -w json | jq -r '.[] | select(.isLeader == true) | .endpoint' | head -1 | cut -d: -f1 | sed 's/https:\/\///')
   if [ "$FAILED_MASTER" == "$PRIMARY_MASTER" ]; then
     echo "Primær master node failure"
   else
     echo "Sekundær master node failure"
   fi
   ```

---

#### Recovery Steps

**Option A: Genstart k3s service**
```bash
# Paa den fejlede master node
ssh $FAILED_MASTER
sudo systemctl restart k3s

# Vent 2 minutter (etcd failover)
sleep 120

# Tjek etcd health
kubectl get --raw /healthz
```

**Option B: Reboot node**
```bash
# Paa den fejlede master node
sudo reboot

# Vent 5 minutter
sleep 300

# Tjek etcd health
kubectl get --raw /healthz
```

**Option C: Erstat master node (hvis hardware failure)**
```bash
# 1. Fjern node fra cluster
kubectl delete node $FAILED_MASTER

# 2. Forbered ny master node
# 3. Installer k3s server med HA
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<primary-master-ip>:6443 \
  --token <token> \
  --tls-san <new-master-ip>

# 4. Verificer etcd health
kubectl get --raw /healthz
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek etcd cluster health
sudo k3s etcdctl endpoint health --endpoints=https://127.0.0.1:2379

# 2. Tjek at alle master nodes er Ready
kubectl get nodes -l node-role.kubernetes.io/master=true

# 3. Tjek at alle pods er scheduled
kubectl get pods -A

# 4. Tjek at alle tenants fungerer
./Scripts/cron.sh test-all-tenants
```

---

---

### SC-04: Full Cluster Outage

**Scenarie:** Hele k3s cluster er nede (alle nodes).

**Symptomer:**
- `kubectl get nodes` fejler
- Alle tenants nedetid
- Ingen adgang til cluster

**Impact:**
- **Kritisk:** Alle tenants nede
- **Data tab:** Ingen (hvis backup tilgangelig)

**RTO:** < 1 time
**RPO:** < 15 minutter

---

#### Detection

**Automatisk detection:**
- Alle monitoring alerts triggeres
- Ingen metrics modtaget

**Manuel detection:**
```bash
# Forsog at tilgå cluster
kubectl get nodes 2>&1 | grep -q "connection refused"
```

---

#### Immediate Actions

1. **Identificer problemet:**
   - Tjek om det er **hardware failure** (alle VMs nede)
   - Tjek om det er **network outage** (se SC-07)
   - Tjek om det er **storage failure** (se SC-05)

2. **Noter tid:**
   ```bash
   INCIDENT_START=$(date -Is)
   echo "Incident start: $INCIDENT_START"
   ```

---

#### Recovery Steps

**Step 1: Genopret infrastructure**
```bash
# Forbered nye servere (samme spec som originale)
# Installer Ubuntu 22.04 LTS
# Konfigurer SSH-adgang
```

**Step 2: Installer k3s HA cluster**
```bash
# Paa master node 1
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san <master1-ip> \
  --tls-san <master2-ip> \
  --tls-san <master3-ip>

K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)

# Paa master node 2 og 3
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<master1-ip>:6443 \
  --token $K3S_TOKEN
```

**Step 3: Restore etcd fra backup**
```bash
# Paa master node 1
sudo systemctl stop k3s

# Download seneste etcd snapshot
aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com cp \
  s3://k3s-backups/etcd-daily-$(date +%Y%m%d).snapshot \
  /var/lib/rancher/k3s/server/db/snapshots/restore.snapshot

# Restore etcd
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/restore.snapshot &

# Vent paa k3s start
sleep 120
```

**Step 4: Deploy infrastructure komponenter**
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

**Step 5: Restore tenants**
```bash
# List alle tenant backups
velero backup get --label-selector saasplatform.dk/tenant=true

# Restore alle tenants
for backup in $(velero backup get -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -E '^tenant-|^daily-'); do
  velero restore create ${backup}-restore-$(date +%Y%m%d%H%M%S) \
    --from-backup $backup \
    --wait \
    --timeout 30m
done
```

**Step 6: Verificer alle tenants**
```bash
# Vent 10 minutter
sleep 600

# Verificer alle tenants
FAILED_TENANTS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  if ! ./Scripts/cron.sh "${ns#tenant-}"; then
    echo "FAIL: Tenant ${ns#tenant-} ikke korer"
    FAILED_TENANTS=$((FAILED_TENANTS + 1))
  fi
done

if [ "$FAILED_TENANTS" -eq 0 ]; then
  echo "SUCCESS: Alle tenants genskabt"
else
  echo "WARNING: $FAILED_TENANTS tenants skal undersoges"
fi
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek cluster status
kubectl get nodes
kubectl get pods -A

# 2. Tjek etcd health
kubectl get --raw /healthz

# 3. Tjek at alle tenants fungerer
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-'); do
  ./Scripts/cron.sh "${ns#tenant-}"
done

# 4. Noter recovery tid
INCIDENT_END=$(date -Is)
RTO=$(( $(date -d "$INCIDENT_END" +%s) - $(date -d "$INCIDENT_START" +%s) ))
echo "RTO: ${RTO} sekunder"
```

---

#### Communication

**Internal:**
- Slack: `@here Full cluster outage resolved - RTO: ${RTO}s`
- Incident log: Dokumenter alle recovery steps

**External:**
- Status page: Opdater med incident og resolution
- Email til kunder: Forklar nedetid og recovery

---

---

### SC-05: Storage Failure

**Scenarie:** Storage backend fejler (PVCs kan ikke mountes).

**Symptomer:**
- Pods er stuck i `Pending` eller `ContainerCreating` state
- `kubectl describe pod` viser `FailedMount` errors
- Storage provider fejl

**Impact:**
- **Hoj:** Tenants med berørte PVCs kan vaere nede
- **Data tab:** Afhaenger af backup

**RTO:** < 1 time
**RPO:** < 15 minutter

---

#### Detection

**Automatisk detection:**
- `KubePodNotReady` alerts for pods med storage problems

**Manuel detection:**
```bash
# Tjek pods med storage problems
kubectl get pods -A -o wide | grep -E "Pending|ContainerCreating"

# Tjek pod events
kubectl describe pod <pod-name> | grep -i "mount\|volume\|storage"

# Tjek PVC status
kubectl get pvc -A
```

---

#### Immediate Actions

1. **Identificer berørte PVCs:**
   ```bash
   FAILED_PVCS=$(kubectl get pvc -A -o jsonpath='{.items[?(@.status.phase!="Bound")].metadata.namespace}/{.items[?(@.status.phase!="Bound")].metadata.name}' | tr ' ' '\n')
   echo "Berørte PVCs:"
   echo "$FAILED_PVCS"
   ```

2. **Identificer berørte tenants:**
   ```bash
   AFFECTED_TENANTS=$(echo "$FAILED_PVCS" | cut -d'/' -f1 | sort -u | grep '^tenant-')
   echo "Berørte tenants:"
   echo "$AFFECTED_TENANTS"
   ```

---

#### Recovery Steps

**Option A: Vent på storage provider recovery**
```bash
# Hvis storage provider forventes at blive fixed
# Vent og monitor
watch -n 30 "kubectl get pvc -A"
```

**Option B: Restore fra backup**
```bash
# For hver berørt tenant
for tenant in $AFFECTED_TENANTS; do
  contract=${tenant#tenant-}
  
  # 1. Tag backup af nuværende state (hvis muligt)
  ./Scripts/beforeundeploy.sh $contract || true
  
  # 2. Slet tenant
  ./Scripts/undeploy.sh $contract
  
  # 3. Restore tenant fra seneste backup
  BACKUP=$(velero backup get --include-namespaces $tenant --sort-by=.status.completionTimestamp --reverse -o jsonpath='{.items[0].metadata.name}')
  velero restore create ${contract}-storage-restore-$(date +%Y%m%d%H%M%S) \
    --from-backup $BACKUP \
    --include-namespaces $tenant \
    --wait \
    --timeout 10m
  
  # 4. Verificer tenant
  ./Scripts/cron.sh $contract
  
  # 5. Noter recovery tid
  echo "Tenant $contract restored"
done
```

**Option C: Flyt til alternativ storage class**
```bash
# For hver berørt PVC
for pvc in $FAILED_PVCS; do
  ns=$(echo $pvc | cut -d'/' -f1)
  name=$(echo $pvc | cut -d'/' -f2)
  
  # Rediger PVC for at bruge alternativ storage class
  kubectl patch pvc -n $ns $name -p '{"spec":{"storageClassName":"fast"}}'
  
  # Slet pod for at force re-mount
  kubectl delete pod -n $ns -l app=dolibarr
  
  # Vent paa pod
  kubectl wait --for=condition=Ready pod -n $ns -l app=dolibarr --timeout=300s
done
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek at alle PVCs er Bound
kubectl get pvc -A

# 2. Tjek at alle pods korer
kubectl get pods -A

# 3. Tjek at alle tenants fungerer
for tenant in $AFFECTED_TENANTS; do
  contract=${tenant#tenant-}
  ./Scripts/cron.sh $contract
done
```

---

---

### SC-06: Database Korruption

**Scenarie:** MariaDB database er korrupt.

**Symptomer:**
- DB pods crashlooper
- `kubectl logs` viser database errors
- Tenant app viser database connection errors

**Impact:**
- **Kritisk:** Berørte tenants kan miste data
- **Data tab:** Afhaenger af backup

**RTO:** < 1 time
**RPO:** < 15 minutter

---

#### Detection

**Automatisk detection:**
- `KubePodCrashLoopBackOff` alerts for DB pods

**Manuel detection:**
```bash
# Tjek DB pod status
kubectl get pods -A -l app.kubernetes.io/component=db

# Tjek DB pod logs
kubectl logs -n <namespace> <db-pod-name> --previous

# Tjek DB connection
kubectl exec -n <namespace> <db-pod-name> -- mysql -e "SELECT 1;"
```

---

#### Immediate Actions

1. **Identificer berørt tenant:**
   ```bash
   FAILED_DB_PODS=$(kubectl get pods -A -l app.kubernetes.io/component=db -o jsonpath='{.items[?(@.status.phase!="Running")].metadata.namespace}' | tr ' ' '\n' | grep '^tenant-')
   echo "Berørte tenants:"
   echo "$FAILED_DB_PODS"
   ```

2. **Tag backup af nuværende DB (hvis muligt):**
   ```bash
   for ns in $FAILED_DB_PODS; do
     contract=${ns#tenant-}
     ./Scripts/beforeundeploy.sh $contract || true
   done
   ```

---

#### Recovery Steps

**Option A: Restart DB pod**
```bash
# For hver berørt tenant
for ns in $FAILED_DB_PODS; do
  kubectl delete pod -n $ns -l app.kubernetes.io/component=db
  sleep 30
  
  # Tjek om pod korer
  if kubectl get pods -n $ns -l app.kubernetes.io/component=db --no-headers | grep -q Running; then
    echo "PASS: DB pod genstartet for $ns"
  else
    echo "FAIL: DB pod korer ikke for $ns"
  fi
done
```

**Option B: Restore DB fra backup**
```bash
# For hver berørt tenant
for ns in $FAILED_DB_PODS; do
  contract=${ns#tenant-}
  
  # 1. Slet DB StatefulSet
  kubectl delete statefulset mariadb -n $ns
  kubectl delete pvc -n $ns --all
  
  # 2. Deploy tenant med suspended=true
  helm upgrade --install tenant-$contract Helm/erp-tenant \
    -n $ns \
    -f $VALUES_DIR/tenant-$contract.yaml \
    --set suspended=true \
    --wait --timeout 5m
  
  # 3. Restore DB dump
  # Find seneste DB dump
  DB_DUMP=$(aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com ls s3://saasplatform-backups/daily/$contract/ | grep -i backup | tail -1 | awk '{print $4}')
  
  if [ -n "$DB_DUMP" ]; then
    aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com cp \
      s3://saasplatform-backups/daily/$contract/$DB_DUMP \
      /tmp/restore-$contract.sql.gz
    
    kubectl exec -n $ns pod/mariadb-0 -- \
      sh -c "zcat /tmp/restore-$contract.sql.gz | mysql -u \$MARIADB_USER -p\$MARIADB_PASSWORD dolibarr"
    
    rm -f /tmp/restore-$contract.sql.gz
  fi
  
  # 4. Unsuspend tenant
  helm upgrade tenant-$contract Helm/erp-tenant \
    -n $ns \
    -f $VALUES_DIR/tenant-$contract.yaml \
    --set suspended=false \
    --wait --timeout 5m
  
  # 5. Verificer tenant
  ./Scripts/cron.sh $contract
  
  echo "Tenant $contract DB restored"
done
```

**Option C: Use pre-migration snapshot**
```bash
# For hver berørt tenant
for ns in $FAILED_DB_PODS; do
  contract=${ns#tenant-}
  
  # Find seneste pre-migration snapshot
  SNAPSHOT=$(aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com ls s3://pre-migration-backups/$contract/ | tail -1 | awk '{print $4}')
  
  if [ -n "$SNAPSHOT" ]; then
    aws s3 --endpoint-url https://s3.eu-central-1.wasabisys.com cp \
      s3://pre-migration-backups/$contract/$SNAPSHOT \
      /tmp/pre-migration-$contract.sql.gz
    
    # Restore (samme procedure som Option B)
    ./Scripts/rollback.sh $contract --snapshot $SNAPSHOT
    
    rm -f /tmp/pre-migration-$contract.sql.gz
  fi
done
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek at alle DB pods korer
kubectl get pods -A -l app.kubernetes.io/component=db

# 2. Tjek DB connection for alle tenants
for ns in $FAILED_DB_PODS; do
  contract=${ns#tenant-}
  DB_CONNECTION=$(kubectl exec -n $ns pod/mariadb-0 -- mysql -e "SELECT 1;" 2>&1)
  if echo "$DB_CONNECTION" | grep -q "1"; then
    echo "PASS: DB connection OK for $contract"
  else
    echo "FAIL: DB connection failed for $contract"
  fi
done

# 3. Tjek at alle tenants fungerer
for ns in $FAILED_DB_PODS; do
  contract=${ns#tenant-}
  ./Scripts/cron.sh $contract
done
```

---

---

### SC-07: Network Outage

**Scenarie:** Network problemer (internt eller eksternt).

**Symptomer:**
- `kubectl get nodes` viser `ConnectionTimeout` errors
- Pods kan ikke kommunikere
- External adgang fejler

**Impact:**
- **Hoj:** Cluster kan vaere delvist eller fuldstændigt utilgangelig
- **Data tab:** Ingen

**RTO:** < 30 minutter
**RPO:** 0

---

#### Detection

**Automatisk detection:**
- `KubeNodeUnreachable` alerts
- `KubeletDown` alerts

**Manuel detection:**
```bash
# Tjek node connectivity
kubectl get nodes

# Tjek pod connectivity
kubectl get pods -A

# Tjek network connectivity fra node
ping 8.8.8.8
curl -v https://api.cloudflare.com
```

---

#### Immediate Actions

1. **Identificer network problemet:**
   ```bash
   # Tjek om det er intern network
   kubectl run network-test --image=busybox --restart=Never --rm -it -- \
     ping -c 4 kube-dns.kube-system.svc.cluster.local
   
   # Tjek om det er ekstern network
   kubectl run network-test --image=busybox --restart=Never --rm -it -- \
     ping -c 4 8.8.8.8
   ```

2. **Tjek firewall og security groups:**
   ```bash
   # Tjek firewall status
   sudo ufw status
   
   # Tjek iptables
   sudo iptables -L -n
   ```

---

#### Recovery Steps

**Option A: Genstart network services**
```bash
# Paa berørte nodes
sudo systemctl restart networking
sudo systemctl restart k3s
```

**Option B: Tjek DNS**
```bash
# Tjek DNS resolution
kubectl run dns-test --image=busybox --restart=Never --rm -it -- \
  nslookup kubernetes.default.svc.cluster.local
```

**Option C: Tjek Cloudflare DNS**
```bash
# Tjek DNS records
dig +short kunder.saasplatform.dk

# Tjek Cloudflare status
curl -v https://www.cloudflarestatus.com
```

**Option D: Tjek Load Balancer**
```bash
# Tjek Traefik service
kubectl get svc -n kube-system traefik

# Tjek Load Balancer IP
kubectl get svc -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Tjek Load Balancer health
curl -v http://<loadbalancer-ip>:8080/healthz
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek at alle nodes er Ready
kubectl get nodes

# 2. Tjek at alle pods er Running
kubectl get pods -A

# 3. Tjek external adgang
curl -v https://test-ha-01.kunder.saasplatform.dk/healthz

# 4. Tjek DNS resolution
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-' | head -5); do
  contract=${ns#tenant-}
  if ! curl -fsS -o /dev/null -m 5 "https://${contract}.kunder.saasplatform.dk/healthz" &>/dev/null; then
    echo "FAIL: External adgang fejler for $contract"
  fi
done
```

---

---

### SC-08: DNS Outage

**Scenarie:** DNS problemer (Cloudflare eller intern DNS).

**Symptomer:**
- DNS resolution fejler
- Nye tenants kan ikke deployes
- Eksisterende tenants kan vaere tilgangelige via IP

**Impact:**
- **Medium:** Nye tenants kan ikke deployes, eksisterende kan vaere tilgangelige
- **Data tab:** Ingen

**RTO:** < 1 time
**RPO:** 0

---

#### Detection

**Automatisk detection:**
- DNS health check alerts

**Manuel detection:**
```bash
# Tjek DNS resolution
dig +short kunder.saasplatform.dk

# Tjek Cloudflare API
curl -v https://api.cloudflare.com/client/v4/zones
```

---

#### Immediate Actions

1. **Tjek Cloudflare status:**
   ```bash
   curl -v https://www.cloudflarestatus.com
   ```

2. **Tjek Cloudflare API token:**
   ```bash
   if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
     echo "WARNING: Cloudflare API token ikke sat"
   fi
   ```

---

#### Recovery Steps

**Option A: Vent på Cloudflare recovery**
```bash
# Hvis Cloudflare har en outage
# Vent og monitor status page
```

**Option B: Opdater DNS manuelt**
```bash
# Opret DNS record manuelt via Cloudflare dashboard
# Eller brug Cloudflare API
curl -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"A","name":"test-ha-01.kunder.saasplatform.dk","content":"<ip>","ttl":300,"proxied":false}'
```

**Option C: Brug /etc/hosts som workaround**
```bash
# Paa test maskiner
sudo sh -c "echo '<ip> test-ha-01.kunder.saasplatform.dk' >> /etc/hosts"
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek DNS resolution
dig +short test-ha-01.kunder.saasplatform.dk

# 2. Tjek at tenants er tilgangelige
for i in $(seq 1 5); do
  if ! curl -fsS -o /dev/null -m 5 "https://test-ha-0${i}.kunder.saasplatform.dk/healthz" &>/dev/null; then
    echo "FAIL: DNS fejler for test-ha-0${i}"
  fi
done
```

---

---

### SC-09: Certificate Expiration

**Scenarie:** TLS certifikater udlober.

**Symptomer:**
- HTTPS adgang fejler med certificate errors
- `kubectl get certificate` viser certifikater med `NotReady` status
- Browser viser certificate warnings

**Impact:**
- **Medium:** HTTPS adgang fejler
- **Data tab:** Ingen

**RTO:** < 1 time
**RPO:** 0

---

#### Detection

**Automatisk detection:**
- `CertificateExpiring` alerts
- `CertificateExpired` alerts

**Manuel detection:**
```bash
# Tjek certificate status
kubectl get certificate -A

# Tjek certificate expiration
kubectl get certificate -n tenant-12345 -o jsonpath='{.status.notAfter}'

# Tjek certifikater der udlober snart
kubectl get certificate -A -o jsonpath='{.items[*].metadata.name}' | \
  xargs -I {} kubectl get certificate {} -o jsonpath='{.metadata.name}{.status.notAfter}' | \
  grep $(date -d "+7 days" +%Y-%m-%d)
```

---

#### Immediate Actions

1. **Identificer udlobede certifikater:**
   ```bash
   EXPIRED_CERTS=$(kubectl get certificate -A -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")].metadata.namespace}/{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")].metadata.name}' | tr ' ' '\n')
   echo "Udlobede certifikater:"
   echo "$EXPIRED_CERTS"
   ```

2. **Tjek cert-manager status:**
   ```bash
   kubectl get pods -n cert-manager
   kubectl logs -n cert-manager -l app=cert-manager
   ```

---

#### Recovery Steps

**Option A: Vent på cert-manager fornyelse**
```bash
# cert-manager burde automatisk forny certifikater
# Tjek status
kubectl describe certificate -n <namespace> <certificate-name>
```

**Option B: Manuelt trigger fornyelse**
```bash
# Slet certificate for at trigger fornyelse
for cert in $EXPIRED_CERTS; do
  ns=$(echo $cert | cut -d'/' -f1)
  name=$(echo $cert | cut -d'/' -f2)
  kubectl delete certificate -n $ns $name
  sleep 30
  kubectl get certificate -n $ns $name
done
```

**Option C: Tjek cert-manager konfiguration**
```bash
# Tjek ClusterIssuer
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod

# Tjek at DNS-01 challenge fungerer
kubectl get challenges -A
```

**Option D: Tjek Cloudflare DNS**
```bash
# Tjek om DNS records kan oprettes
curl -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"TXT","name":"_acme-challenge.test","content":"test","ttl":120}'
```

---

#### Post-Recovery Verifikation

```bash
# 1. Tjek at alle certifikater er Ready
kubectl get certificate -A

# 2. Tjek certificate expiration
kubectl get certificate -A -o jsonpath='{.items[*].status.notAfter}' | sort -u

# 3. Tjek HTTPS adgang for alle tenants
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^tenant-' | head -5); do
  contract=${ns#tenant-}
  if ! curl -fsS -o /dev/null -m 5 "https://${contract}.kunder.saasplatform.dk/healthz" &>/dev/null; then
    echo "FAIL: HTTPS fejler for $contract"
  fi
done
```

---

---

## Post-Mortem Template

```markdown
# Incident Post-Mortem: [Incident Navn]

## Summary
- **Incident ID:** [ID]
- **Date:** [YYYY-MM-DD]
- **Time:** [Start] - [End]
- **Duration:** [X minutter/hours]
- **Severity:** [Critical/High/Medium/Low]
- **Status:** [Resolved/Investigating]

## Impact
- **Affected Services:** [Liste]
- **Affected Tenants:** [Antal]
- **Customer Impact:** [Beskrivelse]
- **Data Loss:** [Ja/Nej]
- **RTO Achieved:** [X minutter]
- **RPO Achieved:** [X minutter]

## Timeline
| Time | Event | Owner |
|------|-------|-------|
| [Tid] | [Beskrivelse] | [Navn] |

## Root Cause
[Detaljeret beskrivelse af root cause]

## Recovery Steps
1. [Step 1]
2. [Step 2]
3. [Step 3]

## Lessons Learned
- [Lesson 1]
- [Lesson 2]

## Action Items
| Task | Owner | Due Date | Status |
|------|-------|----------|--------|
| [Task] | [Navn] | [Dato] | [Status] |

## Follow-up
- [ ] Post-mortem review meeting
- [ ] Action items assigned
- [ ] Documentation updated
- [ ] Monitoring improved
```

---

## DR Test Schedule

| Test | Frekvens | Næste Test | Ansvarlig |
|------|----------|------------|-----------|
| Single Node Failure | Maanedlig | [Dato] | [Navn] |
| Master Node Failure | Kvartalsvis | [Dato] | [Navn] |
| Full Cluster Restore | Halvaarsvis | [Dato] | [Navn] |
| etcd Restore | Kvartalsvis | [Dato] | [Navn] |
| Tenant DR | Maanedlig | [Dato] | [Navn] |
| Database DR | Kvartalsvis | [Dato] | [Navn] |

---

## Kontakter og Ressourcer

### Eksterne Kontakter

| Organisation | Kontakt | Telefon | Email | Formaal |
|--------------|---------|---------|-------|---------|
| Cloudflare | Support | | support@cloudflare.com | DNS, CDN |
| Wasabi | Support | | support@wasabi.com | S3 Storage |
| Hetzner | Support | | support@hetzner.com | Cloud VMs |
| GitHub | Support | | support@github.com | GHCR |

### Interne Ressourcer

- [Arkitektur.md](../Arkitektur.md)
- [Fase 3 README](README.md)
- [Fase 3 Testplan](Testplan.md)
- [Infrastructure/k3s/README.md](../../Infrastructure/k3s/README.md)
- [Infrastructure/velero/README.md](../../Infrastructure/velero/README.md)
- [Infrastructure/monitoring/README.md](../../Infrastructure/monitoring/README.md)

---

## Revision Historik

| Version | Dato | Ændringer | Forfatter |
|--------|------|-----------|-----------|
| 1.0 | [Dato] | Initial version | [Navn] |
