# Fase 2 - Installationstjekliste

**Formaal:** Etablere produktionsklar drift med canary-rollout, observability og backup.
**Exit-kriterier:** Canary-rollout fungerer + Velero backup funktionel + Observability stack funktionel + CI-niveau 2 groen.

---

## Overblik

Fase 2 bygger oven paa fase 1c og tilfoejer:
1. **Canary-rollout infrastructure** (rotationsindeks, stratificeret udvaelgelse)
2. **Observability stack** (Prometheus, Grafana, Loki, Promtail)
3. **Produktions-backup** (Velero + Wasabi S3 + natlig DB-dump)
4. **Produktionsmiljo** (k3s cluster, DNS, SellYourSaaS integration)

---

## Checkliste

### 1. Infrastruktur

#### 1.1 Servere

- [ ] **k3s Master Server**
  - [ ] Dedikeret VM (min. 4 vCPUs, 8GB RAM, 100GB disk)
  - [ ] Ubuntu 22.04 LTS installeret
  - [ ] SSH-adgang konfigureret (SSH keys)
  - [ ] Firewall: port 6443 (k3s API), 22 (SSH) aabne
  - [ ] Hostname sat: `k3s-master.saasplatform.dk`

- [ ] **k3s Worker Nodes** (valgfrit for HA)
  - [ ] Dedikeret VM per node (min. 4 vCPUs, 8GB RAM, 100GB disk)
  - [ ] Ubuntu 22.04 LTS installeret
  - [ ] SSH-adgang konfigureret
  - [ ] Firewall: port 22 (SSH) aaben
  - [ ] Hostname sat: `k3s-worker-{n}.saasplatform.dk`

- [ ] **Runner VM**
  - [ ] Dedikeret VM (min. 2 vCPUs, 4GB RAM, 50GB disk)
  - [ ] Ubuntu 22.04 LTS installeret
  - [ ] SSH-adgang fra SellYourSaaS master
  - [ ] Hostname sat: `runner.saasplatform.dk`

#### 1.2 k3s Cluster

- [ ] **k3s Installation (Master)**
  - [ ] k3s installeret (`curl -sfL https://get.k3s.io | sh -s - --disable traefik --disable servicelb --cluster-init`)
  - [ ] `kubectl get nodes` viser master node med Ready status
  - [ ] `kubectl get pods -A` viser alle system pods koerende
  - [ ] K3S_TOKEN noteret (til worker nodes)

- [ ] **k3s Worker Nodes**
  - [ ] Worker nodes tilfoejet til cluster
  - [ ] `kubectl get nodes` viser alle nodes med Ready status
  - [ ] Node labels sat (node-role.kubernetes.io/worker=true)

- [ ] **k3s Konfiguration**
  - [ ] k3s service konfigureret til at starte ved boot
  - [ ] k3s logs roteret (logrotate konfigureret)
  - [ ] etcd backup konfigureret

#### 1.3 Traefik Ingress Controller

- [ ] **Traefik Installation**
  - [ ] Helm repo tilfoejet (`helm repo add traefik https://traefik.github.io/charts`)
  - [ ] Traefik installeret via Helm
  - [ ] `kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik` viser koerende pods

- [ ] **Traefik Konfiguration**
  - [ ] LoadBalancer service oprettet
  - [ ] LoadBalancer IP noteret
  - [ ] TLS konfigureret (cert-manager integration)
  - [ ] Middleware konfigureret (headers, redirects)

#### 1.4 cert-manager

- [ ] **cert-manager Installation**
  - [ ] CRDs installeret
  - [ ] cert-manager installeret via Helm
  - [ ] `kubectl get pods -n cert-manager` viser koerende pods

- [ ] **cert-manager Konfiguration**
  - [ ] ClusterIssuer (letsencrypt-prod) oprettet
  - [ ] DNS-01 challenge konfigureret (Cloudflare)
  - [ ] Cloudflare API token konfigureret

#### 1.5 SealedSecrets

- [ ] **SealedSecrets Installation**
  - [ ] Controller installeret
  - [ ] `kubectl get pods -n kube-system -l name=sealed-secrets-controller` viser koerende pod

- [ ] **SealedSecrets Konfiguration**
  - [ ] kubeseal CLI installeret paa runner VM
  - [ ] SealedSecrets certifikat hentet og gemt
  - [ ] kubeseal testet (kan kryptere/dekryptere)

#### 1.6 Metrics-server

- [ ] **Metrics-server Installation**
  - [ ] Installeret via Helm
  - [ ] `kubectl get pods -n kube-system -l k8s-app=metrics-server` viser koerende pod
  - [ ] `kubectl top nodes` fungerer

---

### 2. Storage og Backup

#### 2.1 Wasabi S3

- [ ] **Wasabi Konto**
  - [ ] Konto oprettet
  - [ ] Access key og secret key genereret

- [ ] **Wasabi Buckets**
  - [ ] Bucket oprettet: `saasplatform-backups`
  - [ ] Bucket oprettet: `pre-migration-backups`
  - [ ] Region sat: `eu-central-1`
  - [ ] Bucket policies konfigureret (read/write)

- [ ] **S3 Credentials**
  - [ ] Credentials gemt i sealed-secrets
  - [ ] Miljoevariabler sat paa runner VM

#### 2.2 Velero

- [ ] **Velero CLI**
  - [ ] Velero CLI installeret paa runner VM
  - [ ] Velero version verificeret

- [ ] **Velero Installation**
  - [ ] Velero installeret i clusteret
  - [ ] `kubectl get pods -n velero` viser koerende pods
  - [ ] BackupStorageLocation oprettet (Wasabi S3)
  - [ ] VolumeSnapshotLocation oprettet

- [ ] **Velero Backup Schedules**
  - [ ] Natlig backup schedule oprettet
  - [ ] Ugentlig backup schedule oprettet (standard tenants)
  - [ ] Maenedlig backup schedule oprettet (premium tenants)
  - [ ] Pre-migration backup folder oprettet

- [ ] **Velero Verifikation**
  - [ ] Test backup koret
  - [ ] Test backup verificeret i S3
  - [ ] Test restore koret
  - [ ] Test restore verificeret

#### 2.3 Natlig DB-dump

- [ ] **CronJob Konfiguration**
  - [ ] CronJob i Helm chart aktiveret
  - [ ] Schedule sat: `0 2 * * *` (kl. 02:00)
  - [ ] S3 upload aktiveret
  - [ ] Retention sat: 7 dage (standard), 30 dage (premium)

- [ ] **DB-dump Verifikation**
  - [ ] Test DB-dump koret
  - [ ] DB-dump verificeret i S3
  - [ ] DB-dump kan restore

---

### 3. Observability Stack

#### 3.1 Prometheus

- [ ] **Prometheus Installation**
  - [ ] Helm repo tilfoejet
  - [ ] Prometheus installeret via Helm
  - [ ] `kubectl get pods -n monitoring -l app=prometheus` viser koerende pods

- [ ] **Prometheus Konfiguration**
  - [ ] Resources sat (CPU: 2000m, Memory: 8Gi)
  - [ ] Retention sat: 30 dage
  - [ ] Storage konfigureret (50GiB)
  - [ ] Scrape targets konfigureret (k3s, tenants)

- [ ] **Prometheus Verifikation**
  - [ ] Port-forward testet (`kubectl port-forward svc/prometheus 9090:9090`)
  - [ ] Web interface adgang verificeret
  - [ ] Targets viser healthy status

#### 3.2 Grafana

- [ ] **Grafana Installation**
  - [ ] Helm repo tilfoejet
  - [ ] Grafana installeret via Helm
  - [ ] `kubectl get pods -n monitoring -l app=grafana` viser koerende pod

- [ ] **Grafana Konfiguration**
  - [ ] Persistence aktiveret (10Gi)
  - [ ] Admin password sat
  - [ ] Data sources konfigureret (Prometheus, Loki)
  - [ ] Dashboards konfigureret (cluster, tenants, database, application)

- [ ] **Grafana Verifikation**
  - [ ] Port-forward testet (`kubectl port-forward svc/grafana 3000:80`)
  - [ ] Login testet
  - [ ] Dashboards verificeret

#### 3.3 Loki

- [ ] **Loki Installation**
  - [ ] Helm repo tilfoejet
  - [ ] Loki installeret via Helm
  - [ ] `kubectl get pods -n monitoring -l app.kubernetes.io/name=loki` viser koerende pod

- [ ] **Loki Konfiguration**
  - [ ] Resources sat (CPU: 2000m, Memory: 8Gi)
  - [ ] Persistence aktiveret (50Gi)
  - [ ] Replicas sat: 1

- [ ] **Loki Verifikation**
  - [ ] Port-forward testet
  - [ ] Query testet

#### 3.4 Promtail

- [ ] **Promtail Installation**
  - [ ] Installeret via Helm
  - [ ] `kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail` viser koerende pods

- [ ] **Promtail Konfiguration**
  - [ ] Loki client konfigureret
  - [ ] Scrape paths konfigureret

- [ ] **Promtail Verifikation**
  - [ ] Logs sendt til Loki verificeret

#### 3.5 Alerts

- [ ] **Alertmanager Installation**
  - [ ] Inkluderet i Prometheus installation
  - [ ] `kubectl get pods -n monitoring -l app=alertmanager` viser koerende pod

- [ ] **Alert Rules**
  - [ ] Tenant nedetid alert oprettet
  - [ ] High CPU usage alert oprettet
  - [ ] High memory usage alert oprettet
  - [ ] Disk space low alert oprettet
  - [ ] Certificate expiration alert oprettet
  - [ ] Backup failure alert oprettet

- [ ] **Alertmanager Konfiguration**
  - [ ] Slack integration konfigureret
  - [ ] Alert routing konfigureret

- [ ] **Alerts Verifikation**
  - [ ] Test alert triggeret
  - [ ] Alert modtaget i Slack

---

### 4. Canary-rollout

#### 4.1 Rotationsindeks Filer

- [ ] **Directory Struktur**
  - [ ] `/var/lib/saasplatform/` oprettet paa runner VM

- [ ] **Rotationsindeks Filer**
  - [ ] `canary-index-standard-k8s-prod.txt` oprettet
  - [ ] `canary-index-premium-k8s-prod.txt` oprettet
  - [ ] `canary-index-standard-native-prod.txt` oprettet
  - [ ] `canary-index-premium-native-prod.txt` oprettet
  - [ ] Alle filer initialiseret med `0`

- [ ] **Permissions**
  - [ ] Ejerskab sat: `saasplatform:saasplatform`
  - [ ] Lese/skrive permissions verificeret

#### 4.2 Miljoevariabler

- [ ] **Canary Settings**
  - [ ] `CANARY_PERCENTAGE=5` sat i `/etc/saasplatform/config`
  - [ ] `CANARY_PERCENTAGE_PREMIUM=10` sat
  - [ ] `CANARY_WINDOW=1800` sat (30 minutter)

- [ ] **Verifikation**
  - [ ] Miljoevariabler loadet af scripts
  - [ ] Scripts bruger korrekte vaerdier

#### 4.3 Canary-rollout Script

- [ ] **Script Verifikation**
  - [ ] `canary-rollout.sh` findes i Scripts/
  - [ ] Execute permissions sat
  - [ ] Script testet med test tenants

- [ ] **Canary Test**
  - [ ] Test tenants deployet
  - [ ] Canary-rollout koret
  - [ ] Canary tenants identificeret
  - [ ] Healthz checks passeret

---

### 5. DNS og Netvaerk

#### 5.1 DNS (Cloudflare)

- [ ] **DNS Records**
  - [ ] A-record for `@` oprettet (k3s master IP)
  - [ ] A-record for `*.kunder.saasplatform.dk` oprettet (Traefik LB IP)
  - [ ] CNAME for `www` oprettet
  - [ ] A-record for `runner` oprettet (runner VM IP)
  - [ ] TTL sat: 300
  - [ ] Proxy status: DNS only (ikke proxied)

- [ ] **DNS Verifikation**
  - [ ] DNS records resolveret korrekt
  - [ ] Wildcard DNS fungerer

#### 5.2 Netvaerk

- [ ] **Firewall (k3s Master)**
  - [ ] Port 6443 (k3s API) aaben for runner VM
  - [ ] Port 6443 aaben for admin IPs
  - [ ] Port 80/443 aaben (Traefik)
  - [ ] Port 22 aaben (SSH)

- [ ] **Firewall (Runner VM)**
  - [ ] Port 8080 aaben (SellYourSaaS agent)
  - [ ] Port 22 aaben (SSH)

- [ ] **Firewall (Worker Nodes)**
  - [ ] Port 22 aaben (SSH)

---

### 6. SellYourSaaS Integration

#### 6.1 Deployment Servers

- [ ] **k8s-prod Server**
  - [ ] Oprettet i SellYourSaaS
  - [ ] Hostname: `runner.saasplatform.dk`
  - [ ] Port: 8080
  - [ ] Type: kubernetes
  - [ ] Packages: kubernetes-dolibarr

- [ ] **native-prod Server**
  - [ ] Oprettet i SellYourSaaS
  - [ ] Hostname: <native-server-ip>
  - [ ] Port: 8080
  - [ ] Type: native
  - [ ] Packages: native-pim

#### 6.2 Packages

- [ ] **kubernetes-dolibarr Package**
  - [ ] Oprettet i SellYourSaaS
  - [ ] Type: kubernetes
  - [ ] Version: 1.0.0
  - [ ] Git URL: https://github.com/smoeberg/saasplatform
  - [ ] Branch: main
  - [ ] Path: Helm/erp-tenant

- [ ] **native-pim Package**
  - [ ] Oprettet i SellYourSaaS
  - [ ] Type: native
  - [ ] Version: 1.0.0

#### 6.3 Plans

- [ ] **Standard Plan**
  - [ ] Oprettet i SellYourSaaS
  - [ ] CPU: 1
  - [ ] Memory: 2GB
  - [ ] Storage: 5GB
  - [ ] Backup retention: 7 dage

- [ ] **Premium Plan**
  - [ ] Oprettet i SellYourSaaS
  - [ ] CPU: 2
  - [ ] Memory: 4GB
  - [ ] Storage: 20GB
  - [ ] Backup retention: 30 dage

#### 6.4 Payment Gateways

- [ ] **Stripe**
  - [ ] API Key konfigureret
  - [ ] Publishable Key konfigureret
  - [ ] Webhook URL konfigureret

#### 6.5 Suspension Settings

- [ ] **Grace Period**: 7 dage
- [ ] **Suspension Action**: suspend
- [ ] **Unsuspension Action**: unsuspend
- [ ] **Termination Action**: undeploy

---

### 7. Directory Struktur (Runner VM)

- [ ] **Root Directory**
  - [ ] `/opt/saasplatform/` oprettet
  - [ ] Ejerskab: `saasplatform:saasplatform`

- [ ] **Helm Charts**
  - [ ] `/opt/saasplatform/Helm/erp-tenant/` kopieret
  - [ ] Alle chart filer til stede

- [ ] **Values Directory**
  - [ ] `/etc/saasplatform/values/` oprettet
  - [ ] Ejerskab: `saasplatform:saasplatform`

- [ ] **Scripts Directory**
  - [ ] `/opt/saasplatform/Scripts/` oprettet
  - [ ] Alle scripts kopieret
  - [ ] Execute permissions sat
  - [ ] Ejerskab: `saasplatform:saasplatform`

- [ ] **Status Directory**
  - [ ] `/var/lib/saasplatform/status/` oprettet
  - [ ] Ejerskab: `saasplatform:saasplatform`

- [ ] **Backup Directory**
  - [ ] `/var/backups/saasplatform/pre-undeploy/` oprettet
  - [ ] Ejerskab: `saasplatform:saasplatform`

- [ ] **Log Directory**
  - [ ] `/var/log/saasplatform/` oprettet
  - [ ] Ejerskab: `saasplatform:saasplatform`

- [ ] **Configuration**
  - [ ] `/etc/saasplatform/config` oprettet
  - [ ] Alle miljovariabler sat

- [ ] **kubeconfig**
  - [ ] `/etc/saasplatform/kubeconfig` oprettet
  - [ ] Begrenset permissions (kun tenant-* namespaces)

---

### 8. Systemd Services

- [ ] **saasplatform-k8s Service**
  - [ ] Service fil oprettet (`/etc/systemd/system/saasplatform-k8s.service`)
  - [ ] Miljoevariabler konfigureret
  - [ ] WorkingDirectory sat: `/opt/saasplatform/Scripts`
  - [ ] ExecStart sat: `/opt/saasplatform/Scripts/cron.sh`
  - [ ] Restart policy sat: on-failure
  - [ ] Service enabled
  - [ ] Service startet

- [ ] **Service Verifikation**
  - [ ] `systemctl status saasplatform-k8s` viser aktiv (running)
  - [ ] Logs verificeret (`journalctl -u saasplatform-k8s -f`)

---

### 9. Sikkerhed

#### 9.1 k3s Sikkerhed

- [ ] **API Adgang**
  - [ ] Kun tillad fra runner VM IP
  - [ ] Kun tillad fra admin IPs
  - [ ] Firewall regler verificeret

- [ ] **RBAC**
  - [ ] ServiceAccount (saasplatform-runner) oprettet
  - [ ] Role (saasplatform-tenant-admin) oprettet
  - [ ] RoleBinding oprettet
  - [ ] Begrenset kubeconfig oprettet og testet

#### 9.2 Backup Sikkerhed

- [ ] **S3 Credentials**
  - [ ] Gemt i sealed-secrets
  - [ ] Ikke i klartekst paa disk
  - [ ] Minimal permissions (read/write til buckets)

- [ ] **Velero Encryption**
  - [ ] Encryption at rest aktiveret
  - [ ] Encryption key konfigureret

#### 9.3 Monitoring Sikkerhed

- [ ] **Grafana Authentication**
  - [ ] Basic auth aktiveret
  - [ ] Admin password sat
  - [ ] OAuth konfigureret (valgfrit)

- [ ] **Network Policies**
  - [ ] Monitoring namespace begrenset
  - [ ] Egress til S3 tilladt
  - [ ] Ingress fra runner VM tilladt

#### 9.4 Secrets Management

- [ ] **SealedSecrets**
  - [ ] Alle secrets gemt som SealedSecrets
  - [ ] kubeseal cert gemt sikkert
  - [ ] Backup af kubeseal cert

- [ ] **Database Credentials**
  - [ ] Genereret per-tenant
  - [ ] Gemt som SealedSecrets
  - [ ] Ikke i klartekst

---

### 10. Verifikation

#### 10.1 Smoke Tests

- [ ] **Deploy Test**
  - [ ] Test tenant deployet
  - [ ] Healthz check OK
  - [ ] Login fungerer

- [ ] **Suspend Test**
  - [ ] Test tenant suspended
  - [ ] Replicas = 0
  - [ ] CronJobs slettet
  - [ ] Suspended page viser

- [ ] **Unsuspend Test**
  - [ ] Test tenant unsuspended
  - [ ] Replicas = 1
  - [ ] CronJobs genskabt
  - [ ] Healthz check OK

- [ ] **Undeploy Test**
  - [ ] Test tenant undeployet
  - [ ] Namespace slettet
  - [ ] Values-fil slettet

#### 10.2 Canary-rollout Test

- [ ] **Canary Test**
  - [ ] Test tenants deployet
  - [ ] Canary-rollout koret
  - [ ] Korrekt antal canary tenants
  - [ ] Healthz checks passeret
  - [ ] Full rollout koret

#### 10.3 Backup Test

- [ ] **Velero Backup Test**
  - [ ] Backup koret
  - [ ] Backup verificeret i S3
  - [ ] Restore koret
  - [ ] Restore verificeret

- [ ] **DB-dump Test**
  - [ ] DB-dump koret
  - [ ] DB-dump verificeret i S3
  - [ ] DB-dump kan restore

#### 10.4 Monitoring Test

- [ ] **Prometheus Test**
  - [ ] Targets viser healthy
  - [ ] Metrikker indsamlet

- [ ] **Grafana Test**
  - [ ] Login fungerer
  - [ ] Dashboards viser data

- [ ] **Loki Test**
  - [ ] Logs indsamlet
  - [ ] Queries fungerer

- [ ] **Alerts Test**
  - [ ] Test alert triggeret
  - [ ] Alert modtaget

---

### 11. Dokumentation

- [ ] **Fase 2 README**
  - [ ] Oprettet
  - [ ] Komplet dokumentation

- [ ] **Fase 2 Installationstjekliste**
  - [ ] Oprettet
  - [ ] Alle punkter verificeret

- [ ] **Fase 2 Testplan**
  - [ ] Oprettet
  - [ ] Alle tests defineret

- [ ] **Produktions-opsaetningsguide**
  - [ ] Oprettet
  - [ ] Alle steps dokumenteret

- [ ] **Docs/README.md**
  - [ ] Opdateret med fase 2 links

---

### 12. CI/CD

- [ ] **GitHub Actions**
  - [ ] erp-tenant-ci.yml opdateret
  - [ ] integration-tests.yml opdateret
  - [ ] scripts-ci.yml opdateret

- [ ] **CI Tests**
  - [ ] Lint-helm job fungerer
  - [ ] Lint-scripts job fungerer
  - [ ] Unit-test-scripts job fungerer
  - [ ] Integration-test-k3d job fungerer

- [ ] **CI Verifikation**
  - [ ] Alle workflows groenne
  - [ ] PR checks fungerer

---

## Exit Kriterier

### Minimum (for at gaa videre)

- [ ] Canary-rollout fungerer (korrekt antal tenants, healthz OK)
- [ ] Velero backup funktionel (backup + restore)
- [ ] Observability stack funktionel (Prometheus, Grafana, Loki)
- [ ] Produktionsmiljo for begge deployment-typer etableret

### Fuldt (anbefalet)

- [ ] Alle checklist punkter verificeret
- [ ] Alle smoke tests passeret
- [ ] Alle canary-rollout tests passeret
- [ ] Alle backup tests passeret
- [ ] Alle monitoring tests passeret
- [ ] CI-niveau 2 (integrations-test) groen
- [ ] Dokumentation komplet

---

## Ressourcer

- [Fase 2 README](README.md)
- [Produktions-opsaetningsguide](Produktions-opsætningsguide.md)
- [Arkitektur.md](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
