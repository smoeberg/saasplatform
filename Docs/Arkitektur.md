# saasplatform — Arkitektur til SaaS-platform

> Status: rev. 3 (2026-09-25). Besluttet model: **SellYourSaaS forbliver uændret** (frit opdaterbart), to deployment-typer i produktion fra dag ét (native + Kubernetes via package-scripts). Kubernetes-operator/CRD udskudt, indtil antallet af container-tenants vokser.

## 1. Formål og grundidé

saasplatform er en generel platform til drift af SaaS-forretninger:

- **Software leveres pr. kunde** — enten som en native SellYourSaaS-instans eller som containere i Kubernetes.
- **Dolibarr + SellYourSaaS er "single source of truth"** for kunder, abonnementer, økonomi og support.
- Platformen håndterer **onboarding, opdatering, suspension, backup og support** — 100 % automatiseret fra ordre til opsigelse.

### Overvejelser: hvorfor ikke den store API-arkitektur?

En tidligere version (rev. 2) foreslog en egen REST-API (`saasplatformd`) + K8s-operator som platformskerne. Det er arkitektonisk elegant, men for omfattende som et første skridt. Rev. 3 vælger i stedet den letteste integration, der bevarer alle fordelene:

- **Der røres ikke ved koden i SellYourSaaS.** Al tilpasning ligger i packages (data i Dolibarr) og i vores egne shell-scripts. DoliCloud kan udgive nye versioner frit — vi opdaterer modulet uden regressioner.
- **Containere implementeres via en ny package-type**, hvis deploy-scripts kalder `helm`/`kubectl` mod K8s. SellYourSaaS-agenten ved ikke, at der er containere i baggrunden — den kører scripts, som den altid gør.

## 2. Arkitekturprincipper

1. **SellYourSaaS er ikke en kode-afhængighed.** Vi patcher aldrig modulet. Vores tilpasninger ligger i package-konfiguration og scripts. Opdateringer af SellYourSaaS skal altid være sikre.
2. **Én kilde til sandhed pr. datatype.** Dolibarr ejer kunder, kontrakter, fakturering og tickets.
3. **To deployment-typer, endelig tilstand (ikke overgang):**
   - **Native** (Unix-bruger + chroot + FPM + Apache-vhost) til mindre risikable apps (PIM).
   - **Kubernetes** (namespace + Ingress + tenant-DB pr. tenant) til høje sikkerhedskrav (hosted Dolibarr ERP).
4. **Fail-closed.** Udrulninger og ændringer rammer kun produktion, når health-checks er grønne; provisioning-fejl stopper flowet fremfor at efterlade halvfærdige instanser.

## 3. Logisk arkitektur

```
        ┌──────────────────────────────────────────────┐
        │  Dolibarr + SellYourSaaS (master)            │
        │  kunder · packages/services · myaccount      │
        │  Stripe/SEPA · suspension · support · reseller│
        └──────────────┬───────────────────────────────┘
                       │ remote actions (SSH + agent, port 8080)
        ┌──────────────┴────────────────┬──────────────┐
        ▼                               ▼
┌──────────────────┐          ┌─────────────────────────┐
│ Native deployment│          │ K8s-runner              │
│ server           │          │ (lille server/pod med   │
│                  │          │ kubectl + helm +        │
│ PIM m.fl.        │          │ kubeconfig)             │
│ chroot + FPM     │          │                         │
│ (standard SYSAAS)│          │ Dolibarr ERP-tenants:   │
└──────────────────┘          │ namespace + Ingress +   │
                              │ tenant-DB pr. kunde     │
                              └─────────────────────────┘
```

### 3.1 Hvad vi genbruger uændret fra SellYourSaaS

- **Package-modellen**: En *Package* definerer produktet (sources, config-templates, SQL-after-deploy, cron-templates, shell-after-deploy).
- **Service-modellen**: En service kobler pakken til abonnement, pris, options og metrics. Kvoter pr. kunde/IP/tidsvindue er en del af plandefinitionen.
- **Kundecenter (myaccount)**, **Stripe/SEPA + suspension**, **support/tickets**, **reseller-netværk**, **manuel admin-override** (deploy/suspend/undeploy/password-reset).

### 3.2 Package-type "kubernetes" — integrationen

En ny package, hvor alle shell-scripts kalder K8s. Eksempel på package-felter:

- `sources`: tomt (installeres ikke på runneren — imaget findes allerede i GHCR)
- `afterdeploy`: script, der kører `helm upgrade --install tenant-$INSTANCE {chart}` med `-f` pr. instans
- `afterundeploy`: `helm uninstall tenant-$INSTANCE; kubectl delete ns tenant-$INSTANCE`
- `aftersuspend`: `kubectl scale --replicas=0 deploy/... -n tenant-$INSTANCE` + Ingress → "suspended"-vhost
- `afterunsuspend`: skalering tilbage + genopretning af Ingress
- `refresh`: re-apply af ønsket tilstand (re-converge)
- `cron`: ekstern health-check af tenant-URL (f.eks. `/healthz`) fra runner

**Vigtigt:** Package-konfigurationen skal desuden sikre, at SellYourSaaS kan overvåge instansen. Agenten tjekker tenantens Ingress-URL som health-check (f.eks. `/healthz`-endepunktet i chartet).

### 3.3 Dataplane: Dolibarr ERP pr. tenant

- 1 namespace/tenant: `tenant-{contract-id}`
- Deployment + Service + Ingress (Traefik) + cert-manager-TLS
- **Tenant-specifikt DB-StatefulSet** (MariaDB) i samme namespace
- NetworkPolicy (default deny) + ResourceQuota
- Secrets via sealed-secrets (fase 1)
- PVC til Dolibarr-dokumenter

**Suspension:** Skala-til-nul + blokeret Ingress; PVC'er bevares; CronJobs suspenderes; retention: 90 dage, herefter slettes (GDPR) — konfigurerbart pr. plan.

**Backup:** Natlig Velero (namespace) + natlig DB-dump (mysqldump) til S3-kompatibel storage, udført samtidigt (ikke forskudt). 7 dages retention på standard, 30 dage + binlog-stream (point-in-time) på premium. Gendannelse af enkelt tenant: Velero-restore + indlæsning af matchende DB-dump.

### 3.4 Dataplane: PIM og andre lavrisiko-apps

Køres på **standard SellYourSaaS native deployment-servere** (Unix-bruger + chroot + FPM + separat DB). Meget lave omkostninger (<0,50 USD/instans ifølge DoliCloud). En moderat sikkerhedsrisiko accepteres — PIM har typisk en mindre angrebsflade end et ERP med regnskab og persondata.

### 3.5 Opdatering af tenant-software

- Nyt image i GHCR via CI → ny package-version i SellYourSaaS.
- Udrulning i grupper: canary (5–10 %, stratificeret efter plan og deployment-server, roteret så det ikke altid er de samme kunder, der tester først) → 30–60 min. overvågning → udrulning til alle.
- Fail-closed; rollback pr. tenant (sæt tidligere version i package/contract og re-apply).
- Native apps opdateres via SellYourSaaS' indbyggede `master_redeploy_instances`-mønster (batch + canary).

### 3.6 Observability og skaleringsmål

- Mål: **10 tenants i fase 1, 100+ i fase 2, 1000+ i fase 3** — dimensioneringen følger heraf.
- Loki + Prometheus/Grafana; labels (`tenant_id`) — ikke separate instanser pr. tenant.
- Dashboard pr. tenant: health via tenant-URL + SellYourSaaS' supervision.
- K8s-operator/CRD udskudt: Helm + cron-controllere er tilstrækkeligt til 10–50 tenants. Beslutningen genbesøges, når antallet af Dolibarr-tenants overstiger ~50.

## 4. Teknologistak

| Lag | Valg | Begrundelse |
|---|---|---|
| Management plane | SellYourSaaS (uændret Dolibarr-modul) | gennemtestet; gratis opdateringer |
| K8s-runner | Lille server/pod med kubectl + helm + kubeconfig | SellYourSaaS-agenten kører scripts som normalt |
| Dataplane (ERP) | k3s, Traefik, cert-manager, sealed-secrets, tenant-DB | Strikt isolation pr. tenant |
| Dataplane (PIM) | SellYourSaaS native | Billigt, gennemprøvet, moderat risiko |
| Observability | Prometheus + Grafana + Loki | Standard, open source |
| Registry | GHCR | Allerede på GitHub |

## 5. Implementeringsfaser

**Fase 1a — forretningsflowet (uge 1–3)**
1. Installér Dolibarr + SellYourSaaS (master + 1 native deployment-server) i dev; gennemfør: registrering → deploy (native) → betaling → suspension.
2. Deployér PIM som første native package; verificér hele flowet med PIM.

**Fase 1b — K8s-integration (uge 3–6)**
3. Sæt k3s-cluster op (Traefik, cert-manager, sealed-secrets) + K8s-runner med kubectl/helm/kubeconfig.
4. Byg "kubernetes"-package til Dolibarr: Helm-chart (namespace, DB, Ingress, cert-manager) + 8 shell-scripts til de 8 remote actions.
5. Verificér flowet end-to-end: ny testkunde → Helm-deploy → fakturering → suspension → undeploy.

**Fase 2 — produktion (uge 6–12)**
6. Produktionsmiljø for begge deployment-typer; Velero + natlig DB-dump; DNS-automatisering pr. tenant.
7. Canary-rollout-rutine til opdateringer; dashboards og alerts.

**Fase 3 — skalering**
8. Revurdering af operator/CRD ved ~50 Dolibarr-tenants; reseller-netværk; external-secrets.

## 6. Risici og beslutninger

- **SellYourSaaS-agenten forventer vhost/DNS/health-mønstre** — vores Helm-chart skal give agenten noget at overvåge (Ingress-URL med health-endepunkt). Defineres i package-konfigurationen.
- **K8s er dyrere pr. instans end native** — accepteret for Dolibarr-ERP pga. sikkerhedskrav; PIM og lignende køres native for at holde omkostningerne nede.
- **GPL-bemærkning**: server-side-brug udløser ikke udleveringspligt; hvis modulet distribueres til kunder (on-prem), udløses GPL's distributionspligt.
- **Én primær vedligeholder upstream** (DoliCloud) — accepteret, netop fordi vi ikke patcher: versionsfrys er ikke nødvendig, men vi følger udgivelser og tester opdateringer i dev først.
- **Dolibarr-webhooks er ikke pålidelige** — periodisk polling er en fast del af designet.
