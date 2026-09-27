# Fase 3 - Installationstjekliste

**Formaal:** Implementere skalering, high availability og disaster recovery.
**Exit-kriterier:** k3s cluster kan skaleres horisontalt + HA konfiguration + DR procedurer testet + RTO < 1 time + RPO < 15 minutter.

---

## Overblik

Fase 3 bygger oven paa fase 2 og tilfoejer:
1. **Skalering** (horisontal, vertikal, auto-scaling)
2. **High Availability** (multi-master, HA for kritiske komponenter)
3. **Disaster Recovery** (backup, restore, runbooks)
4. **Monitoring og Alerting** for HA/DR

---

## Checkliste

---

### 1. Skalering

#### 1.1 Horisontal Skalering (k3s Nodes)

- [ ] **k3s Cluster Forberedelse**
  - [ ] Nuværende cluster status dokumenteret
  - [ ] Nuværende node count noteret
  - [ ] Node specifikationer dokumenteret
  - [ ] K3S_TOKEN noteret (til nye nodes)

- [ ] **Tilfoej Worker Nodes**
  - [ ] 2+ ekstra worker nodes forberedt
  - [ ] Ubuntu 22.04 LTS installeret paa alle nodes
  - [ ] SSH-adgang konfigureret (master -> workers)
  - [ ] Firewall regler konfigureret (port 6443)
  - [ ] Node labels sat (node-role.kubernetes.io/worker=true)
  - [ ] Nodes tilfoejet til cluster
  - [ ] `kubectl get nodes` viser alle nodes med Ready status

- [ ] **Node Labels og Taints**
  - [ ] Standard nodes labelet (saasplatform.dk/node-type=standard)
  - [ ] Premium nodes labelet (saasplatform.dk/node-type=premium)
  - [ ] Database nodes labelet (saasplatform.dk/node-type=database)
  - [ ] Taints sat for dedikerede nodes (dedicated=database:NoSchedule)

- [ ] **Node Affinity**
  - [ ] Premium tenants konfigureret til at bruge premium nodes
  - [ ] Database workloads konfigureret til at bruge database nodes
  - [ ] Affinity rules testet

- [ ] **Node Removal**
  - [ ] Drain procedure testet
  - [ ] Node removal procedure testet
  - [ ] Node rejoin procedure testet

#### 1.2 Vertikal Skalering (Resources)

- [ ] **Tenant Resource Skalering**
  - [ ] Standard tenant resources dokumenteret
  - [ ] Premium tenant resources dokumenteret
  - [ ] Enterprise tenant resources defineret
  - [ ] Skaleringsprocedure testet

- [ ] **Cluster Resource Skalering**
  - [ ] k3s Master resources justeret
  - [ ] Resource limits konfigureret
  - [ ] CPUQuota og MemoryLimit sat

- [ ] **ResourceQuota**
  - [ ] Standard tenant quota konfigureret
  - [ ] Premium tenant quota konfigureret
  - [ ] Enterprise tenant quota konfigureret

#### 1.3 Auto-Scaling

- [ ] **Horizontal Pod Autoscaler (HPA)**
  - [ ] HPA template oprettet (90-hpa.yaml)
  - [ ] HPA konfiguration i values.yaml
  - [ ] HPA testet (men deaktiveret som default)
  - [ ] Dokumentation om ReadWriteOnce begrensning

- [ ] **Cluster Autoscaler**
  - [ ] Cluster-autoscaler installeret
  - [ ] Auto-discovery konfigureret
  - [ ] Scale-down settings konfigureret
  - [ ] Resource limits sat

- [ ] **Auto-Scaling Tests**
  - [ ] HPA test (manuelt)
  - [ ] Cluster-autoscaler test (manuelt)
  - [ ] Scale-down test

#### 1.4 Storage Skalering

- [ ] **PVC Resizing**
  - [ ] Storage class understotter resizing
  - [ ] PVC resizing procedure testet
  - [ ] Dokumentation opdateret

- [ ] **Storage Classes**
  - [ ] fast storage class oprettet
  - [ ] slow storage class oprettet
  - [ ] Default storage class sat

- [ ] **Storage Monitoring**
  - [ ] Storage capacity alerts konfigureret
  - [ ] Storage usage dashboards oprettet

---

### 2. High Availability

#### 2.1 k3s High Availability

- [ ] **Multi-Master Setup**
  - [ ] 3 master nodes forberedt
  - [ ] Ubuntu 22.04 LTS installeret paa alle masters
  - [ ] SSH-adgang konfigureret (master <-> master)
  - [ ] k3s HA cluster initialiseret
  - [ ] `kubectl get nodes` viser alle masters

- [ ] **etcd Cluster**
  - [ ] etcd cluster health verificeret
  - [ ] etcd members list verificeret
  - [ ] etcd snapshot procedure testet

- [ ] **Load Balancer**
  - [ ] HAProxy installeret
  - [ ] HAProxy konfigureret for k3s
  - [ ] Load balancer testet
  - [ ] Failover testet

- [ ] **Master Node Failure Test**
  - [ ] Single master failure testet
  - [ ] etcd failover verificeret
  - [ ] Cluster fortsaetter med at fungere

#### 2.2 Traefik High Availability

- [ ] **Traefik HA Konfiguration**
  - [ ] replicaCount sat til 3
  - [ ] PodDisruptionBudget konfigureret
  - [ ] Resources justeret
  - [ ] Node selector konfigureret

- [ ] **Traefik HA Deployment**
  - [ ] Traefik HA deployet
  - [ ] Traefik pods fordelte paa nodes
  - [ ] Load balancing testet

- [ ] **Traefik HA Verifikation**
  - [ ] Alle Traefik pods korer
  - [ ] Ingress fortsaetter med at fungere ved pod failure

#### 2.3 Prometheus High Availability

- [ ] **Prometheus HA Konfiguration**
  - [ ] replicaCount sat til 2
  - [ ] Retention justeret
  - [ ] Thanos integration konfigureret
  - [ ] PodDisruptionBudget konfigureret

- [ ] **Prometheus HA Deployment**
  - [ ] Prometheus HA deployet
  - [ ] Thanos sidecar installeret
  - [ ] Metrikker replikeret

- [ ] **Alertmanager HA**
  - [ ] replicaCount sat til 2
  - [ ] PodDisruptionBudget konfigureret

#### 2.4 Database High Availability

- [ ] **MariaDB HA Valg**
  - [ ] Galera cluster vs. ProxySQL evalueret
  - [ ] Beslutning dokumenteret (se DECISIONS.md)

- [ ] **MariaDB HA Implementation**
  - [ ] Galera cluster konfigureret (hvis valgt)
  - [ ] ProxySQL konfigureret (hvis valgt)
  - [ ] HA template oprettet

- [ ] **Database HA Test**
  - [ ] Database failover testet
  - [ ] Read/write testet
  - [ ] Performance testet

---

### 3. Disaster Recovery

#### 3.1 Backup Infrastructure

- [ ] **etcd Backup**
  - [ ] Automatisk etcd backup konfigureret
  - [ ] etcd snapshot schedule oprettet
  - [ ] etcd backup til S3 konfigureret
  - [ ] etcd backup testet

- [ ] **Velero Backup**
  - [ ] Velero installeret (fra fase 2)
  - [ ] Backup schedules konfigureret
  - [ ] Retention policies sat
  - [ ] S3 credentials konfigureret

- [ ] **Backup Verifikation**
  - [ ] Daglig backup verifikation
  - [ ] Backup stoerrelse monitoring
  - [ ] Backup success alerts

#### 3.2 DR Procedurer

- [ ] **DR Plan**
  - [ ] DR scenarier dokumenteret
  - [ ] RTO og RPO defineret
  - [ ] DR team kontaktliste oprettet

- [ ] **Full Cluster Restore Procedure**
  - [ ] Cluster restore procedur dokumenteret
  - [ ] Tenant restore procedur dokumenteret
  - [ ] Database restore procedur dokumenteret

- [ ] **DR Runbooks**
  - [ ] Cluster nedetid runbook
  - [ ] Tenant nedetid runbook
  - [ ] Backup failure runbook

#### 3.3 DR Tests

- [ ] **Full Cluster Restore Test**
  - [ ] Test cluster oprettet
  - [ ] Full backup taget
  - [ ] Cluster destroyed
  - [ ] Cluster restored
  - [ ] Tenants verificeret

- [ ] **etcd Restore Test**
  - [ ] etcd snapshot taget
  - [ ] etcd destroyed
  - [ ] etcd restored
  - [ ] Cluster verificeret

- [ ] **Tenant DR Test**
  - [ ] Tenant backup taget
  - [ ] Tenant destroyed
  - [ ] Tenant restored
  - [ ] Data verificeret

- [ ] **Database DR Test**
  - [ ] Database backup taget
  - [ ] Database destroyed
  - [ ] Database restored
  - [ ] Data verificeret

---

### 4. Monitoring og Alerting for HA/DR

#### 4.1 Prometheus Alerts

- [ ] **HA Alerts**
  - [ ] ClusterNodeDown alert
  - [ ] HighNodeFailure alert
  - [ ] etcdHighCommitLatency alert
  - [ ] etcdNoLeader alert

- [ ] **DR Alerts**
  - [ ] BackupFailure alert
  - [ ] NoRecentBackup alert
  - [ ] TenantDown alert (udvidet)

- [ ] **Alertmanager Konfiguration**
  - [ ] Slack integration konfigureret
  - [ ] PagerDuty integration konfigureret (valgfrit)
  - [ ] Alert routing konfigureret

#### 4.2 Grafana Dashboards

- [ ] **HA Dashboard**
  - [ ] Cluster node status
  - [ ] etcd health
  - [ ] Backup status
  - [ ] Tenant health overview

- [ ] **DR Dashboard**
  - [ ] Backup history
  - [ ] Restore history
  - [ ] RTO/RPO tracking

- [ ] **Incident Response Dashboard**
  - [ ] Active alerts
  - [ ] Recent incidents
  - [ ] On-call rotation

---

### 5. Dokumentation

#### 5.1 Fase 3 Dokumentation

- [ ] **Fase 3 README**
  - [ ] Oprettet
  - [ ] Komplet oversigt
  - [ ] Alle procedurer dokumenteret

- [ ] **Fase 3 Installationstjekliste**
  - [ ] Oprettet
  - [ ] Alle punkter verificeret

- [ ] **Fase 3 Testplan**
  - [ ] Oprettet
  - [ ] Alle tests defineret

- [ ] **Disaster Recovery Dokumentation**
  - [ ] Oprettet
  - [ ] Alle DR procedurer dokumenteret

#### 5.2 Opdateret Dokumentation

- [ ] **Docs/README.md**
  - [ ] Opdateret med fase 3 links

- [ ] **Helm/erp-tenant/README.md**
  - [ ] Opdateret med HA/DR information

- [ ] **DECISIONS.md**
  - [ ] Opdateret med fase 3 beslutninger

---

### 6. Sikkerhed

#### 6.1 SecurityContext

- [ ] **Dolibarr SecurityContext**
  - [ ] runAsNonRoot: true
  - [ ] readOnlyRootFilesystem: true
  - [ ] allowPrivilegeEscalation: false
  - [ ] capabilities.drop: ALL
  - [ ] seccompProfile: RuntimeDefault

- [ ] **MariaDB SecurityContext**
  - [ ] runAsNonRoot: true
  - [ ] readOnlyRootFilesystem: false
  - [ ] allowPrivilegeEscalation: false
  - [ ] capabilities.drop: ALL
  - [ ] seccompProfile: RuntimeDefault
  - [ ] podSecurityContext.fsGroup: 1001

- [ ] **CronJob SecurityContext**
  - [ ] Backup CronJob securityContext
  - [ ] Pre-migration CronJob securityContext

- [ ] **SecurityContext Verifikation**
  - [ ] Alle pods bruger securityContext
  - [ ] Ingen pods korer som root
  - [ ] Ingen privilege escalation

#### 6.2 Network Policies

- [ ] **HA Network Policies**
  - [ ] Master <-> Master kommunikation tilladt
  - [ ] Master <-> Worker kommunikation tilladt
  - [ ] etcd kommunikation tilladt

- [ ] **Storage Network Policies**
  - [ ] S3 adgang tilladt
  - [ ] NFS adgang tilladt (hvis brugt)

---

### 7. Performance

#### 7.1 Performance Monitoring

- [ ] **Performance Metrikker**
  - [ ] CPU usage
  - [ ] Memory usage
  - [ ] Disk I/O
  - [ ] Network I/O

- [ ] **Performance Dashboards**
  - [ ] Cluster performance dashboard
  - [ ] Tenant performance dashboard
  - [ ] Node performance dashboard

#### 7.2 Performance Testing

- [ ] **Load Testing**
  - [ ] k6 load test konfigureret
  - [ ] Load test udfort
  - [ ] Performance baseline etableret

- [ ] **Stress Testing**
  - [ ] Stress test udfort
  - [ ] Failure threshold identificeret

---

## Exit Kriterier

### Minimum (for at gaa videre til fase 4)

- [ ] k3s cluster kan skaleres til 3+ nodes
- [ ] HA konfiguration for kritiske komponenter
- [ ] DR procedurer dokumenteret
- [ ] RTO < 1 time verificeret
- [ ] RPO < 15 minutter verificeret

### Fuldt (anbefalet)

- [ ] Alle checklist punkter verificeret
- [ ] Alle HA tests passeret
- [ ] Alle DR tests passered
- [ ] Alle dokumentation komplet
- [ ] Runbooks testet
- [ ] Team training udfort

---

## Ressourcer

- [Fase 3 README](README.md)
- [Fase 3 Testplan](Testplan.md)
- [Disaster Recovery Dokumentation](Disaster-Recovery.md)
- [Arkitektur.md](../Arkitektur.md)
- [DECISIONS.md](../DECISIONS.md)
- [Fase 2 Dokumentation](../Fase2/README.md)

---

## Kontakter

- **Primary On-Call:** +45 XX XX XX XX
- **Secondary On-Call:** +45 XX XX XX XX
- **Database Specialist:** +45 XX XX XX XX
- **Infrastructure Lead:** +45 XX XX XX XX
