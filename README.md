# saasplatform

Platform til håndtering af SaaS-tenants: [SellYourSaaS](https://github.com/DoliCloud/sellyoursaas) (uændret) til kunder/abonnementer/fakturering + Kubernetes-runner til containerbaserede tenants.

## 📚 Dokumentation

| Fase | Beskrivelse | Status | Dokumentation |
|------|-------------|--------|----------------|
| **Fase 1a** | Native deployment (PIM) | ✅ Færdig | [Installationstjekliste](Docs/Fase%201a%20Installationstjekliste.md), [README](Docs/Fase1a/README.md) |
| **Fase 1b** | K8s grundintegration | ✅ Færdig | [Installationstjekliste](Docs/Fase1b/Installationstjekliste.md), [README](Docs/Fase1b/README.md), [Testplan](Docs/Fase1b/Testplan.md) |
| **Fase 1c** | Livscyklus & gendannelse | ✅ Færdig | [Installationstjekliste](Docs/Fase1c/Installationstjekliste.md), [README](Docs/Fase1c/README.md), [Testplan](Docs/Fase1c/Testplan.md) |
| **Fase 2** | Produktion | ⏳ Ikke startet | [Produktions-opsætningsguide](Docs/Fase2/README.md), [Produktions-opsætningsguide](Docs/Fase2/Produktions-ops%C3%A6tningsguide.md) |

**Se også:**
- [📖 Dokumentationsindex](Docs/README.md) - Komplet oversigt over al dokumentation
- [🏗️ Arkitektur](Docs/Arkitektur.md) (rev. 6) - Systemdesign og beslutninger
- [📋 Beslutningslog](Docs/DECISIONS.md) - Hvorfor bag hver arkitekturbeslutning

---

## 📁 Struktur

| Mappe | Indhold |
|---|---|
| [Docs/](Docs/) | Arkitektur, faser, beslutninger, testplaner |
| [Docs/Fase1a/](Docs/Fase1a/) | Native deployment (PIM) |
| [Docs/Fase1b/](Docs/Fase1b/) | K8s grundintegration |
| [Docs/Fase1c/](Docs/Fase1c/) | Livscyklus, backup, restore, rollback |
| [Docs/Fase2/](Docs/Fase2/) | Produktionsopsætning |
| [Scripts/](Scripts/) | Remote-action-scripts til K8s-runneren (`lib.sh` + 8 actions) |
| [Helm/](Helm/) | Helm-chart (`erp-tenant`) med suspended-support, MariaDB, Ingress, NetworkPolicy, ResourceQuota |
| [Helm/erp-tenant/](Helm/erp-tenant/) | Per-tenant Dolibarr ERP chart |
| [CI/](CI/) | Mock-agent-harness + GitHub Actions (protokol-test + k3d-integrationstest) |
| [Packages/](Packages/) | Package definitioner (pim-native, kubernetes-dolibarr) |
| [Infrastructure/](Infrastructure/) | k3s, monitoring, native, velero konfigurationer |

---

## 🚀 Hurtig start (dev)

### Med k3d (lokalt Kubernetes)

```bash
# 1. Opret k3d cluster
k3d cluster create saas-test --agents 2 --ports '80:80@loadbalancer' --ports '443:443@loadbalancer'

# 2. Installer afhængigheder (cert-manager, SealedSecrets, Velero, MinIO)
# Se: Docs/Fase1b/README.md

# 3. Kør tests
./CI/run-tests.sh
```

### Med eksisterende cluster

```bash
# Konfigurer miljø
kubectl config use-context your-cluster

# Installer afhængigheder
./Infrastructure/k3s/setup.sh

# Deploy test-tenant
./Scripts/deploy.sh test-01
```

---

## 🎯 Næste Skridt

### For nye bidragydere

1. **Læs arkitekturen:** [Docs/Arkitektur.md](Docs/Arkitektur.md)
2. **Start med fase 1a:** [Docs/Fase1a/README.md](Docs/Fase1a/README.md)
3. **Gå videre til fase 1b:** [Docs/Fase1b/README.md](Docs/Fase1b/README.md)
4. **Test livscyklus:** [Docs/Fase1c/README.md](Docs/Fase1c/README.md)

### For produktion

- [ ] Fase 1a: Native deployment ✅
- [ ] Fase 1b: K8s grundintegration ✅
- [ ] Fase 1c: Livscyklus & gendannelse ✅
- [ ] **Fase 2:** Produktionsopsætning (næste prioritet)

---

## 📖 Arkitektur Beslutninger

| Beslutning | Begrundelse | Reference |
|------------|-------------|-----------|
| SellYourSaaS uændret | Frit opdaterbart, kompleks driftssikret kode | [Arkitektur §1](Docs/Arkitektur.md#1-formål-og-grundidé) |
| Dolibarr = source of truth | Kunder, kontrakter, fakturering, support | [Arkitektur §1](Docs/Arkitektur.md#1-formål-og-grundidé) |
| To deployment-typer | Native (PIM) + K8s (Dolibarr ERP) | [Arkitektur §2.4](Docs/Arkitektur.md#34-dataplane-pim-og-andre-lavrisiko-apps) |
| k3s + Traefik | Minimal, en binær, Traefik inkluderet | [Arkitektur §4](Docs/Arkitektur.md#4-teknologistak) |
| MariaDB 11.4 LTS | Dolibarr-kompatibel, LTS til 2029 | [Arkitektur §4](Docs/Arkitektur.md#4-teknologistak) |
| Wasabi S3 | Lav pris, ingen egress-gebyrer | [Arkitektur §4](Docs/Arkitektur.md#4-teknologistak) |
| Cloudflare DNS | Billigt, API-drevet, hurtig propagation | [Arkitektur §4](Docs/Arkitektur.md#4-teknologistak) |

Se [Docs/DECISIONS.md](Docs/DECISIONS.md) for komplet beslutningslog.

---

## 🤝 Bidrag

- **Issues:** Opret issue i repositoryet
- **Pull Requests:** Velkommen!
- **Spørgsmål:** Se [Docs/README.md](Docs/README.md) for FAQ

---

## 📄 Licens

Dette projekt er licenseret under GPL-3.0 - se [LICENSE](LICENSE) for detaljer.

**Note:** Egne scripts og Helm-charts er egen kode (ikke GPL-smittet) - se [Arkitektur §6.3](Docs/Arkitektur.md).
