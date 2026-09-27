# Fase 1b - Installationstjekliste

**Formål:** Implementere K8s-grundintegration for Dolibarr ERP-tenants.
**Exit-kriterier:** 10 fulde gennemløb + cert-manager fornyelse under suspension verificeret + CI-niveau 1 grøn.

---

## 📋 Checkliste

### ✅ 1. k3s Cluster

- [ ] **Server**
  - [ ] Dedikeret VM (min. 4 vCPU, 8GB RAM, 100GB disk)
  - [ ] Ubuntu 22.04 LTS installeret
  - [ ] SSH-adgang konfigureret
  - [ ] Firewall: port 6443, 80, 443, 22 åbne

- [ ] **k3s Installation**
  - [ ] k3s installeret (`curl -sfL https://get.k3s.io | sh -s - --disable traefik`)
  - [ ] `kubectl get nodes` viser ready status
  - [ ] `kubectl get pods -A` viser alle pods kørende

- [ ] **Traefik Ingress Controller**
  - [ ] Traefik installeret via Helm
  - [ ] LoadBalancer service oprettet
  - [ ] LoadBalancer IP noteret

- [ ] **cert-manager**
  - [ ] CRDs installeret
  - [ ] cert-manager installeret via Helm
  - [ ] ClusterIssuer (letsencrypt-prod) oprettet

- [ ] **SealedSecrets**
  - [ ] Controller installeret
  - [ ] kubeseal CLI installeret på runner
  - [ ] SealedSecrets certifikat hentet

- [ ] **Velero** (forberedt til fase 1c)
  - [ ] Velero CLI installeret
  - [ ] Velero installeret i clusteret

---

### ✅ 2. K8s-Runner VM

- [ ] **VM**
  - [ ] Dedikeret VM (min. 2 vCPU, 4GB RAM, 50GB disk)
  - [ ] Ubuntu 22.04 LTS
  - [ ] SSH-adgang fra SellYourSaaS master

- [ ] **Afhængigheder**
  - [ ] kubectl installeret
  - [ ] Helm installeret
  - [ ] yq installeret
  - [ ] jq installeret
  - [ ] curl installeret

- [ ] **kubeconfig**
  - [ ] kubeconfig kopieret fra k3s server
  - [ ] kubeconfig placeret i `/etc/saasplatform/kubeconfig`
  - [ ] Adgang testet (`kubectl get nodes`)

- [ ] **RBAC**
  - [ ] ServiceAccount (saasplatform-runner) oprettet
  - [ ] Role (saasplatform-tenant-admin) oprettet
  - [ ] RoleBinding oprettet
  - [ ] Begrænset kubeconfig oprettet

- [ ] **Directory Struktur**
  - [ ] `/opt/saasplatform/Helm/erp-tenant/` oprettet
  - [ ] `/etc/saasplatform/values/` oprettet
  - [ ] `/var/lib/saasplatform/status/` oprettet
  - [ ] `/var/backups/saasplatform/pre-undeploy/` oprettet
  - [ ] `/var/log/saasplatform/` oprettet

- [ ] **Helm Chart & Scripts**
  - [ ] Helm chart (erp-tenant) kopieret til `/opt/saasplatform/Helm/erp-tenant/`
  - [ ] Alle scripts kopieret til `/opt/saasplatform/scripts/`
  - [ ] Execute permissions sat på scripts
  - [ ] Ejerskab sat (saasplatform:saasplatform)

- [ ] **Systemd Service**
  - [ ] Service fil oprettet (`/etc/systemd/system/saasplatform-k8s.service`)
  - [ ] Miljøvariabler konfigureret
  - [ ] Service enabled og startet

---

### ✅ 3. Dolibarr Kubernetes Package

- [ ] **Package Definition**
  - [ ] Package oprettet i SellYourSaaS (dolibarr-k8s)
  - [ ] Type: kubernetes
  - [ ] Version: 1.0.0
  - [ ] Description: Dolibarr ERP med Kubernetes deployment

- [ ] **Sources**
  - [ ] Git URL: https://github.com/smoeberg/saasplatform
  - [ ] Branch: main
  - [ ] Path: Helm/erp-tenant

- [ ] **Remote Actions**
  - [ ] beforedeploy: `/opt/saasplatform/scripts/beforedeploy.sh`
  - [ ] afterdeploy: `/opt/saasplatform/scripts/afterdeploy.sh`
  - [ ] beforeundeploy: `/opt/saasplatform/scripts/beforeundeploy.sh`
  - [ ] afterundeploy: `/opt/saasplatform/scripts/afterundeploy.sh`
  - [ ] aftersuspend: `/opt/saasplatform/scripts/aftersuspend.sh`
  - [ ] afterunsuspend: `/opt/saasplatform/scripts/afterunsuspend.sh`
  - [ ] refresh: `/opt/saasplatform/scripts/refresh.sh`
  - [ ] recreateauthorizedkeys: `/opt/saasplatform/scripts/recreateauthorizedkeys.sh`
  - [ ] cron: `/opt/saasplatform/scripts/cron.sh`

- [ ] **Config Templates**
  - [ ] values.yaml template oprettet
  - [ ] Render path: `/etc/saasplatform/values/tenant-{{contract_id}}.yaml`

---

### ✅ 4. DNS Automatisering

- [ ] **Cloudflare**
  - [ ] API Token oprettet (Zone:DNS:Edit)
  - [ ] Zone ID noteret
  - [ ] Token og Zone ID gemt på runner VM

- [ ] **DNS Test**
  - [ ] Test deploy kørt
  - [ ] DNS record oprettet
  - [ ] DNS propagation verificeret

---

## 🧪 Test Scenarier

### 📝 5. Normal Flow (10 gennemløb)

| # | Test | Status | Noter |
|---|------|--------|-------|
| 1 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 2 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 3 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 4 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 5 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 6 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 7 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 8 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 9 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |
| 10 | Kunde registrerer sig → deploy → betaling → aktiv | [ ] | |

**Kommando:**
```bash
./Scripts/deploy.sh test-{n}
```

---

### 📝 6. Suspension Tests (5 gennemløb)

| # | Test | Status | Noter |
|---|------|--------|-------|
| 1 | Betaling udløber → suspension → workloads=0, CronJobs slettet | [ ] | |
| 2 | Betaling udløber → suspension → workloads=0, CronJobs slettet | [ ] | |
| 3 | Betaling udløber → suspension → workloads=0, CronJobs slettet | [ ] | |
| 4 | Betaling udløber → suspension → workloads=0, CronJobs slettet | [ ] | |
| 5 | Betaling udløber → suspension → workloads=0, CronJobs slettet | [ ] | |

**Kommando:**
```bash
./Scripts/suspend.sh test-{n}
```

**Verifikation:**
```bash
kubectl get pods -n tenant-test-{n}  # Forventet: 0 pods
kubectl get cronjob -n tenant-test-{n}  # Forventet: ingen cronjobs
```

---

### 📝 7. Unsuspension Tests (5 gennemløb)

| # | Test | Status | Noter |
|---|------|--------|-------|
| 1 | Betaling genoptages → unsuspend → workloads=1, CronJobs genskabt | [ ] | |
| 2 | Betaling genoptages → unsuspend → workloads=1, CronJobs genskabt | [ ] | |
| 3 | Betaling genoptages → unsuspend → workloads=1, CronJobs genskabt | [ ] | |
| 4 | Betaling genoptages → unsuspend → workloads=1, CronJobs genskabt | [ ] | |
| 5 | Betaling genoptages → unsuspend → workloads=1, CronJobs genskabt | [ ] | |

**Kommando:**
```bash
./Scripts/unsuspend.sh test-{n}
```

**Verifikation:**
```bash
kubectl get pods -n tenant-test-{n}  # Forventet: pods kørende
kubectl get cronjob -n tenant-test-{n}  # Forventet: cronjobs til stede
```

---

### 📝 8. Undeploy Tests (5 gennemløb)

| # | Test | Status | Noter |
|---|------|--------|-------|
| 1 | Kontrakt opsagt → undeploy → namespace slettet | [ ] | |
| 2 | Kontrakt opsagt → undeploy → namespace slettet | [ ] | |
| 3 | Kontrakt opsagt → undeploy → namespace slettet | [ ] | |
| 4 | Kontrakt opsagt → undeploy → namespace slettet | [ ] | |
| 5 | Kontrakt opsagt → undeploy → namespace slettet | [ ] | |

**Kommando:**
```bash
./Scripts/undeploy.sh test-{n}
```

**Verifikation:**
```bash
kubectl get namespace tenant-test-{n} --ignore-not-found  # Forventet: not found
ls /etc/saasplatform/values/tenant-test-{n}.yaml  # Forventet: not found
```

---

### 📝 9. cert-manager Fornyelse Test

| # | Test | Status | Noter |
|---|------|--------|-------|
| 1 | Deploy tenant → vent på certifikat → suspend → vent 1 min → tjek fornyelse | [ ] | |

**Kommando:**
```bash
# Deploy
./Scripts/deploy.sh cert-test-1

# Vent på certifikat (30-60 sekunder)
sleep 30

# Suspender
./Scripts/suspend.sh cert-test-1

# Vent 1 minut (cert-manager check interval)
sleep 60

# Tjek certifikat status
CERT_STATUS=$(kubectl get certificate -n tenant-cert-test-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[[ "$CERT_STATUS" == "True" ]] && echo "✅ PASS" || echo "❌ FAIL"
```

---

### 📝 10. Fejl-Injektion Tests

| # | Test | Scenarie | Status | Noter |
|---|------|----------|--------|-------|
| 1 | Deploy fejler | Ugyldige values (mangler domain) | [ ] | |
| 2 | Suspend fejler | Release findes ikke | [ ] | |
| 3 | Healthz timeout | HEALTHZ_TIMEOUT=5 | [ ] | |
| 4 | DB-pod ikke fundet | Ingen mariadb pod | [ ] | |

---

## 📊 Test Resultater

### Samlet Status

| Kategori | Total | Bestået | Fejlet | % |
|----------|-------|---------|--------|---|
| Normal Flow | 10 | 0 | 0 | 0% |
| Suspension | 5 | 0 | 0 | 0% |
| Unsuspension | 5 | 0 | 0 | 0% |
| Undeploy | 5 | 0 | 0 | 0% |
| cert-manager | 1 | 0 | 0 | 0% |
| Fejl-Injektion | 4 | 0 | 0 | 0% |
| **Total** | **25** | **0** | **0** | **0%** |

---

## ✅ Exit Kriterier

### Minimum (for at gå videre til fase 1c)

- [ ] 10 fulde gennemløb af normal flow
- [ ] 5 suspension tests
- [ ] 5 unsuspension tests
- [ ] 5 undeploy tests
- [ ] cert-manager fornyelse under suspension verificeret
- [ ] Protokol-test (CI-niveau 1) grøn

### Fuldt (anbefalet)

- [ ] Alle 25 tests bestået
- [ ] Fejl-injektion tests bestået
- [ ] Alle exit-kriterier dokumenteret
- [ ] Runbook for fejlfinding oprettet

---

## 📚 Dokumentation

- [Fase 1b - Installationstjekliste](README.md)
- [Arkitektur Dokumentation](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)

---

## 🔧 Fejlfinding

Se [README.md](README.md#11-fejlfinding) for detaljeret fejlfinding.
