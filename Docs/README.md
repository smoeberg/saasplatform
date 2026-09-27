# 📚 saasplatform Dokumentation

Velkommen til dokumentationen for **saasplatform** - en platform til håndtering af SaaS-tenants med [SellYourSaaS](https://github.com/DoliCloud/sellyoursaas) og Kubernetes.

---

## 🗺️ Dokumentationsoversigt

```
📁 Docs/
├── 📖 README.md                    ← DU ER HER
├── 🏗️ Arkitektur.md               # Systemdesign, principper, teknologistak
├── 📋 DECISIONS.md               # Beslutningslog (hvorfor bag hver beslutning)
│
├── 📁 Fase1a/                     # Native Deployment (PIM)
│   ├── README.md                 # Komplet installationsguide
│   └── Installationstjekliste.md # Checkliste med exit-kriterier
│
├── 📁 Fase1b/                     # K8s Grundintegration
│   ├── README.md                 # k3s, cert-manager, SealedSecrets, Velero
│   ├── Installationstjekliste.md # 30+ testpunkter
│   └── Testplan.md               # 10 test-cases med kommandoer
│
├── 📁 Fase1c/                     # Livscyklus & Gendannelse
│   ├── README.md                 # Backup, migrate, rollback, restore
│   ├── Installationstjekliste.md # 18+ testpunkter
│   └── Testplan.md               # 8 test-cases (5 kritiske)
│
└── 📁 Fase2/                      # Produktion
    ├── README.md                 # Produktionsflow
    └── Produktions-opsætningsguide.md # Komplet opsætningsguide
```

---

## 🎯 Hurtig Start

### Ny bruger? Start her:

1. **Forstå arkitekturen** → [Arkitektur.md](Arkitektur.md)
2. **Læs beslutningsloggen** → [DECISIONS.md](DECISIONS.md)
3. **Start med fase 1a** → [Fase1a/README.md](Fase1a/README.md)

### Udvikler?

```bash
# Hurtig opsætning (se Fase1b for detaljer)
k3d cluster create saas-test --agents 2
./CI/run-tests.sh
```

---

## 📖 Dokumentation per Fase

### 🟢 Fase 1a: Native Deployment

**Formål:** Bevise forretningsflowet (registrering → deploy → betaling → suspension) med PIM som første native package.

| Dokument | Beskrivelse | Status |
|----------|-------------|--------|
| [README](Fase1a/README.md) | Komplet installationsguide | ✅ |
| [Installationstjekliste](Fase%201a%20Installationstjekliste.md) | Checkliste med exit-kriterier | ✅ |

**Exit-kriterier:**
- 10 fulde gennemløb
- 2 fejl-injektion tests
- Ingen halvfærdige instanser

---

### 🟢 Fase 1b: K8s Grundintegration

**Formål:** Implementere Kubernetes deployment-type for Dolibarr ERP-tenants.

| Dokument | Beskrivelse | Status |
|----------|-------------|--------|
| [README](Fase1b/README.md) | k3s cluster, K8s-runner, DNS, test | ✅ |
| [Installationstjekliste](Fase1b/Installationstjekliste.md) | 30+ checkpunkter | ✅ |
| [Testplan](Fase1b/Testplan.md) | 10 test-cases | ✅ |

**Exit-kriterier:**
- 10 deploy/suspend/unsuspend/undeploy tests
- cert-manager fornyelse under suspension ✅
- CI-niveau 1 (protokol-test) grøn

---

### 🟢 Fase 1c: Livscyklus & Gendannelse

**Formål:** Verificere livscyklus-management (opdatering, rollback, restore, secrets).

| Dokument | Beskrivelse | Status |
|----------|-------------|--------|
| [README](Fase1c/README.md) | Backup, migrate, rollback, restore | ✅ |
| [Installationstjekliste](Fase1c/Installationstjekliste.md) | 18+ checkpunkter | ✅ |
| [Testplan](Fase1c/Testplan.md) | 8 test-cases (5 kritiske) | ✅ |

**Exit-kriterier:**
- **1c-01** Pre-migration snapshot ✅
- **1c-02** Fejlet migrering + rollback ✅
- **1c-03** Restore fra backup ✅
- **1c-04** Secrets-flow verificeret ✅
- CI-niveau 2 (integrations-test) grøn

---

### 🟡 Fase 2: Produktion

**Formål:** Produktionsmiljø for begge deployment-typer.

| Dokument | Beskrivelse | Status |
|----------|-------------|--------|
| [README](Fase2/README.md) | Produktionsflow | ⏳ |
| [Produktions-opsætningsguide](Fase2/Produktions-ops%C3%A6tningsguide.md) | Komplet guide | ⏳ |

**Planlagt indhold:**
- Canary-rollout rutine
- Velero natlig backup
- Monitoring (Prometheus + Grafana + Loki)
- Alerts og dashboards
- Runbooks for drift

---

## 🏗️ Arkitektur Dokumentation

| Dokument | Beskrivelse |
|----------|-------------|
| [Arkitektur.md](Arkitektur.md) | **Hoveddokument** - Systemdesign, principper, dataplane, teknologistak |
| [DECISIONS.md](DECISIONS.md) | Beslutningslog - "hvorfor" bag hver arkitekturbeslutning |

### Nøgleafsnit i Arkitektur.md

| Afsnit | Emne |
|--------|------|
| §1 | Formål og grundidé |
| §2 | Arkitekturprincipper |
| §3 | Logisk arkitektur (dataplane, native, K8s) |
| §3.3 | Dataplane: Dolibarr ERP pr. tenant |
| §3.3.1 | Instance↔namespace-mapping og secrets-flow |
| §3.5 | Opdatering af tenant-software (canary, rollback) |
| §3.7 | K8s-runner hardening og placering |
| §4 | Teknologistak (DNS, S3, MariaDB, k3s, Traefik) |
| §5 | Implementeringsfaser |
| §6 | Risici, beslutninger, failure modes |

---

## 🛠️ Teknisk Dokumentation

### Helm Charts

| Chart | Beskrivelse | Sti |
|-------|-------------|-----|
| **erp-tenant** | Per-tenant Dolibarr ERP | [Helm/erp-tenant/](../Helm/erp-tenant/) |

**erp-tenant features:**
- ✅ Dolibarr Deployment med healthz
- ✅ MariaDB StatefulSet
- ✅ Ingress med Traefik + cert-manager TLS
- ✅ NetworkPolicy (default deny + selective egress)
- ✅ ResourceQuota per tenant
- ✅ **Suspended support** (replicas=0, CronJobs slettet)
- ✅ Pre-migration snapshot CronJob
- ✅ Backup CronJob (natlig)
- ✅ SealedSecret placeholder for DB credentials

---

### Scripts

| Script | Beskrivelse | SellYourSaaS Action |
|--------|-------------|---------------------|
| `lib.sh` | Fælles funktioner og konfiguration | - |
| `deploy.sh` | Deploy tenant | afterdeploy |
| `suspend.sh` | Suspender tenant | aftersuspend |
| `unsuspend.sh` | Genoptag tenant | afterunsuspend |
| `undeploy.sh` | Slet tenant | afterundeploy |
| `beforedeploy.sh` | Pre-flight checks | beforedeploy |
| `beforeundeploy.sh` | Backup før sletning | beforeundeploy |
| `refresh.sh` | Re-apply ønsket tilstand | refresh |
| `migrate.sh` | Håndter migrering | - |
| `rollback.sh` | Rollback til tidligere version | - |
| `restore-tenant.sh` | Restore fra backup | - |
| `cron.sh` | Healthz check af alle tenants | cron |
| `recreateauthorizedkeys.sh` | SSH key rotation | recreateauthorizedkeys |
| `canary-check.sh` | Canary health check | - |
| `canary-rollout.sh` | Canary rollout | - |
| `verify-secrets-flow.sh` | Verificer secrets-flow | - |

**Se:** [Scripts/README.md](../Scripts/README.md) for detaljer.

---

## 🔍 Søg i Dokumentationen

| Emne | Dokument |
|-------|----------|
| Native deployment | [Fase1a/](Fase1a/) |
| k3s cluster setup | [Fase1b/README.md](Fase1b/README.md) |
| K8s-runner VM | [Fase1b/README.md](Fase1b/README.md) |
| Helm chart | [Helm/erp-tenant/README.md](../Helm/erp-tenant/README.md) |
| Backup & Restore | [Fase1c/README.md](Fase1c/README.md) |
| Migrering & Rollback | [Fase1c/README.md](Fase1c/README.md) |
| Secrets-flow | [Fase1c/README.md](Fase1c/README.md) |
| Testplaner | [Fase1b/Testplan.md](Fase1b/Testplan.md), [Fase1c/Testplan.md](Fase1c/Testplan.md) |
| Arkitektur | [Arkitektur.md](Arkitektur.md) |
| Beslutninger | [DECISIONS.md](DECISIONS.md) |

---

## 📊 Test Dokumentation

### Test Niveauer

| Niveau | Beskrivelse | Frekvens | Status |
|--------|-------------|----------|--------|
| **1** | Protokol-test (mock-agent) | Ved hver commit | ✅ Implementeret |
| **2** | Integrations-test (rigtig K8s) | Nightly | ✅ Implementeret |
| **3** | Canary-test | Ved version opdatering | ⏳ Planlagt |

### Test Matrix

| Fase | Tests | CI Workflow | Status |
|------|-------|-------------|--------|
| 1a | 10+2 gennemløb | - | ✅ |
| 1b | 10+5+5+5+1+4 = 30 | [erp-tenant-ci.yml](../.github/workflows/erp-tenant-ci.yml) | ✅ |
| 1c | 8+3 = 11 | [erp-tenant-ci.yml](../.github/workflows/erp-tenant-ci.yml) | ✅ |

---

## 🎨 Diagrammmer

### Arkitektur Diagram (fra Arkitektur.md §3)

```
        ┌─────────────────────────────────────────────────────────┐
        │  Dolibarr + SellYourSaaS (master)                     │
        │  kunder · packages/services · myaccount               │
        │  Stripe/SEPA · suspension · support · reseller        │
        └───────────────────────────┬───────────────────────────┘
                                │ remote actions (SSH + agent, port 8080)
        ┌───────────────────────────┴───────────────────────────┐
        │                                                           │
┌─────────────┐          ┌─────────────────────────────────────┐
│ Native       │          │ K8s-runner (VM uden for clusteret, §3.7)│
│ deployment   │          │ kubectl + helm + kubeconfig          │
│ server       │          │                                     │
│ PIM m.fl.    │          │ Dolibarr ERP-tenants:               │
│ chroot + FPM │          │ namespace + Ingress + tenant-DB     │
└─────────────┘          │ pr. kunde                           │
                             └─────────────────────────────────────┘
```

---

## 🔗 Eksterne Ressourcer

| Ressource | Link |
|-----------|------|
| SellYourSaaS | [GitHub](https://github.com/DoliCloud/sellyoursaas) |
| Dolibarr | [dolibarr.org](https://www.dolibarr.org/) |
| k3s | [docs.k3s.io](https://docs.k3s.io/) |
| Helm | [helm.sh](https://helm.sh/) |
| Traefik | [doc.traefik.io](https://doc.traefik.io/) |
| cert-manager | [cert-manager.io](https://cert-manager.io/) |
| SealedSecrets | [GitHub](https://github.com/bitnami-labs/sealed-secrets) |
| Velero | [velero.io](https://velero.io/) |
| MinIO | [min.io](https://min.io/) |
| Wasabi | [wasabi.com](https://wasabi.com/) |
| Cloudflare | [api.cloudflare.com](https://api.cloudflare.com/) |

---

## 📝 Bidrag

### Hvordan bidrage

1. **Fork** repositoryet
2. **Opret en branch** (`git checkout -b feature/ny-funktion`)
3. **Commit** dine ændringer (`git commit -m 'feat: tilføj ny funktion'`)
4. **Push** til branch (`git push origin feature/ny-funktion`)
5. **Opret Pull Request**

### Dokumentationsstandarder

- Brug **Markdown** format
- Hold filer **korte og fokuserede**
- Link til **andre dokumenter** i stedet for at duplicere indhold
- Brug **kodeblokke** for kommandoer
- Marker **kritiske punkter** med ⚠️
- Marker **exit-kriterier** med ✅

### Code Standarder

- Følg **eksisterende stil**
- Brug **shellcheck** til scripts
- Test **idempotens** (scripts skal kunne køres flere gange)
- **Fail-closed** princip (fejl skal stoppe flowet)

---

## 🚨 Fejl og Support

### Almindelige Problemer

| Problem | Løsning | Dokument |
|---------|---------|----------|
| k3d cluster fejler | Tjek docker og k3d logs | [Fase1b/README.md](Fase1b/README.md) |
| Helm deploy fejler | Tjek values.yaml og chart | [Helm/erp-tenant/README.md](../Helm/erp-tenant/README.md) |
| cert-manager fejler | Tjek ClusterIssuer og DNS | [Fase1b/README.md](Fase1b/README.md) |
| Backup fejler | Tjek Velero og S3 | [Fase1c/README.md](Fase1c/README.md) |
| Rollback fejler | Tjek snapshot og version | [Fase1c/README.md](Fase1c/README.md) |

### Få Hjælp

1. **Læs dokumentationen** (du er her!)
2. **Tjek logs** (`kubectl logs`, `journalctl`)
3. **Søg i issues** på GitHub
4. **Opret et nyt issue** med detaljer

---

## 📄 Licens og Rettigheder

- **Licens:** GPL-3.0 (se [LICENSE](../LICENSE))
- **Egen kode:** Scripts og Helm-charts er egen kode (ikke GPL-smittet)
- **SellYourSaaS:** GPL-3.0 (uændret, se [DoliCloud/sellyoursaas](https://github.com/DoliCloud/sellyoursaas))

---

## 🔄 Versionshistorik

| Version | Dato | Beskrivelse |
|---------|------|-------------|
| 0.1.0 | 2026-09-25 | Initial arkitektur (rev. 6) |
| 0.2.0 | 2026-09-27 | Fase 1a dokumentation |
| 0.3.0 | 2026-09-27 | Helm chart erp-tenant + Fase 1b dokumentation |
| 0.4.0 | 2026-09-27 | Fase 1c dokumentation + Dokumentationsindex |

---

## 🎯 Næste Skridt

### For Projektet

- [ ] **Fase 2:** Produktionsopsætning
- [ ] **CI/CD:** Udvid testdækning
- [ ] **Monitoring:** Prometheus + Grafana + Loki
- [ ] **Canary:** Implementer canary-rollout

### For Dig

- [ ] **Læs** [Arkitektur.md](Arkitektur.md)
- [ ] **Prøv** fase 1a i et testmiljø
- [ ] **Bidrag** med feedback eller code
- [ ] **Del** med andre

---

*Sidst opdateret: 2026-09-27*
*Dokumentationsversion: 0.4.0*
