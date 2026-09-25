# saasplatform — Arkitektur til SaaS-platform

> Status: rev. 4 (2026-09-25). Besluttet model: **SellYourSaaS forbliver uændret** (frit opdaterbart), to deployment-typer i produktion fra dag ét (native + Kubernetes via package-scripts). Kubernetes-operator/CRD udskudt, indtil antallet af container-tenants vokser.
>
> Rev. 4 tilføjer driftsdelen: runner-hardening, backup/restore-runbook, præciseret suspension, canary-algoritme, produktklassificering, testmatrix, escape hatch og DNS-automatisering i fase 1b.

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
│ Native deployment│          │ K8s-runner (VM uden for  │
│ server           │          │ clusteret, §3.7)        │
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

> **Deployment-afslutning:** `afterdeploy` efterlader et verificerbart artefakt til agenten (se også Scripts/README.md), så SellYourSaaS registrerer instansen som "deployed".

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

**Omkostningsbeslutning**: database pr. tenant er dyrere (100 tenants = 100 StatefulSets med hver sin PVC og backup). Det accepteres **for alle Dolibarr-tenants** pga. sikkerheds- og restore-kravet; delt DB med schema-isolation overvejes ikke i fase 1–2 og kun som eksplicit beslutning ved >1000 tenants.
- Secrets via sealed-secrets (fase 1)
- PVC til Dolibarr-dokumenter

**Suspension (præciseret):**
- Workloads (Deployments + StatefulSets) skaleres til 0; **PVC'er bevares**.
- **CronJobs slettes** (ikke skaleres) — Helm-chartet genskaber dem ved unsuspend (deklarativt, `helm upgrade --reuse-values`).
- Event-/job-køer: suspenderes sammen med workloads (ingen pods → ingen forbrugere; kø er DB-baseret og følger tenant-DB'en).
- **cert-manager**: suspenderet Ingress kan bryde HTTP-01-fornyelse. Derfor: suspenderet Ingress bevarer en minimal ACM E-rute til `/.well-known/acme-challenge/` — certifikater fornyes under suspension; hvis det alligevel mislykkes, fornyes ved unsuspend (accepteret, op til 90 dages udløb).
- **Retention-tælling**: 90 dage tæller **fra suspension** (ikke fra opsigelse). Varsling til kunden sker fra kundecenteret (SellYourSaaS' dunning-e-mails), retention er en plan-parameter.

**Backup (præciseret):**
- **Konsistens**: DB-dump køres med `mysqldump --single-transaction` (InnoDB-konsistenspunkt); Velero-snapshot tages **efter** vellykket dump, så dokumenter/PVC altid er ≥ DB-tilstanden. Premium: binlog-stream giver point-in-time recovery.
- **Restore-runbook (rækkefølge)**:
  1. Opret frisk namespace + helm-install med **ingen** data (pods stoppet).
  2. Indlæs DB-dump (seneste konsistente punkt, valgt pr. tidspunkt).
  3. Velero-restore af PVC (documents).
  4. Start pods; verificér `/healthz` + login; varsel om manglende match mellem documents og DB.
- **Restore testes i fase 1b** (én tenant), ikke først i fase 2. Se testmatrixen i §5.

### 3.7 K8s-runner — hardening og placering

**Placering: uden for clusteret** (lille dedikeret VM). Begrundelse: nemmere at drifte, kubeconfig kan roteres uafhængigt, og runneren kompromitterer ikke clusteret indvendigt. Runneren har **ingen adgang til tenant-data** — kun til K8s-API.

- **Dedikeret service-account** i K8s med **minimal RBAC**: kun namespaces med prefix `tenant-*` (Role via `ResourceNames`/namespace-selector), ikke cluster-admin.
- **Logning**: alle `kubectl`/`helm`-kald logges (journald + fjernt syslog).
- **Heartbeat**: runneren skriver et timestamp (cron, hvert 5. min.) tilbage til SellYourSaaS (via en simpel HTTP-endepunkt eller `refresh`-liggende call). Udeblivelse → alarm i SellYourSaaS' supervision.
- **Fail-closed ved runner-nedbrud**: remote actions fejler synligt i SellYourSaaS (agentens fejlrappportering); genoptagelse = re-kør action (alle scripts er idempotente).
- **Skalering**: én runner pr. K8s-cluster fra start; aktiv/passiv-tilføjelse kan ske senere uden migrering (SellYourSaaS tillader flere deployment-servere).

### 3.4 Dataplane: PIM og andre lavrisiko-apps

Køres på **standard SellYourSaaS native deployment-servere** (Unix-bruger + chroot + FPM + separat DB). Meget lave omkostninger (<0,50 USD/instans ifølge DoliCloud).

**Produktklassificering — hvem må køre hvad:**

| Produkttype | Deployment | Begrundelse |
|---|---|---|
| PIM, kataloger, markedsføringsværktøjer (ingen persondata) | Native | Mindre angrebsflade; lav isolationskrav |
| ERP, CRM, HR, regnskab (regnskabs-/persondata) | **K8s** | Hård isolation kræves (namespace + NetworkPolicy) |
| Nyt produkt med persondata — stadig native? | **K8s** | Standard-regel: persondata → K8s |

- **Risiko-acceptancen ejes af CEO/CTO** (documenteres i nyprodukt-godkendelse).
- **Exit-plan**: hvis et native-produkt viser sig at have større angrebsflade end antaget (f.eks. tredjepartsmoduler med API-adgang), flyttes det til K8s — tidsbudget: én sprint per produkt, da chartet er generisk.

### 3.5 Opdatering af tenant-software

- Nyt image i GHCR via CI → ny package-version i SellYourSaaS.
- Udrulning i grupper: canary → 30–60 min. overvågning → udrulning til alle.
- **Canary-algoritme (præciseret)**:
  - Tenants grupperes pr. strata (plan × deployment-server).
  - Inden for hvert stratum: tenants sorteres pr. kontrakt-id; **rotationsindeks gemmes i Dolibarr** (fx i en extrafield); næste canary = indeks mod N, derefter indeks+1 osv.
  - Med 10 tenants og 5–10 % canary er der reelt 1 tenant pr. gang — rotationen sikrer, at alle gennemgår canary over tid (ingen kunde er permanent "kanin").
  - **Opt-out er en plan-parameter**: premium-kunder kan fravælge canary (de rammes kun af promoted-versioner).
- Fail-closed; rollback pr. tenant (sæt tidligere version i package/contract og re-apply).
- Native apps opdateres via SellYourSaaS' indbyggede `master_redeploy_instances`-mønster (batch + canary).

### 3.6 Observability og skaleringsmål

- Mål: **10 tenants i fase 1, 100+ i fase 2, 1000+ i fase 3** — dimensioneringen følger heraf.
- Loki + Prometheus/Grafana; labels (`tenant_id`) — ikke separate instanser pr. tenant.
- **Kendt skaleringsgrænse**: ved **>200 tenants** revurderes Loki (sharded konfiguration) og Prometheus-kardinaliteten (reduktion af per-tenant-labels); Capsule/vCluster evalueres ved **>1000**. Dette er en kendt begrænsning — ikke en fase-1-opgave.
- Dashboard pr. tenant: health via tenant-URL + SellYourSaaS' supervision.
- K8s-operator/CRD udskudt: Helm + cron-controllere er tilstrækkeligt til 10–50 tenants. Beslutningen genbesøges, når antallet af Dolibarr-tenants overstiger ~50.

## 4. Teknologistak

| Lag | Valg | Begrundelse |
|---|---|---|
| Management plane | SellYourSaaS (uændret Dolibarr-modul) | gennemtestet; gratis opdateringer |
| K8s-runner | Dedikeret VM **uden for** clusteret (kubectl + helm + kubeconfig) | Nemmere at drifte/rotere kubeconfig; angrebflade uden for clusteret (se §3.7) |
| Dataplane (ERP) | k3s, Traefik, cert-manager, sealed-secrets, tenant-DB | Strikt isolation pr. tenant |
| Dataplane (PIM) | SellYourSaaS native | Billigt, gennemprøvet, moderat risiko |
| Observability | Prometheus + Grafana + Loki | Standard, open source |
| Registry | GHCR | Allerede på GitHub |

## 5. Implementeringsfaser

**Fase 1a — forretningsflowet (uge 1–3)**
1. Installér Dolibarr + SellYourSaaS (master + 1 native deployment-server) i dev; gennemfør: registrering → deploy (native) → betaling → suspension.
2. Deployér PIM som første native package; verificér hele flowet med PIM.
3. **Dev-instans af SellYourSaaS kører altid nyeste version** — brud opdages tidligt, før produktion rammes.

**Fase 1b — K8s-integration (uge 3–6)**
4. Sæt k3s-cluster op (Traefik, cert-manager, sealed-secrets) + K8s-runner (VM, §3.7) med kubectl/helm/kubeconfig.
5. Byg "kubernetes"-package til Dolibarr: Helm-chart (namespace, DB, Ingress, cert-manager) + 8 shell-scripts til de 8 remote actions.
6. **DNS-automatisering allerede her** (DNS-provider-API i deploy-scriptet) — ellers er "end-to-end" ikke reelt end-to-end. Hvis ikke, dokumenteres manuel DNS eksplicit som fase-1b-begrænsning.
7. Verificér flowet end-to-end: ny testkunde → Helm-deploy → fakturering → suspension → undeploy.
8. **Testet restore af én tenant** (runbook §3.3) — exit-kriterium for fase 1b.

**Fase 2 — produktion (uge 6–12)**
9. Produktionsmiljø for begge deployment-typer; Velero + natlig DB-dump.
10. Canary-rollout-rutine til opdateringer; dashboards og alerts.

**Fase 3 — skalering**
11. Revurdering af operator/CRD ved ~50 Dolibarr-tenants; reseller-netværk; external-secrets.

### 5.1 Testmatrix og exit-kriterier

| Fase | Scenarier | Exit-kriterium |
|---|---|---|
| 1a | Registrering, betaling (godkendt + afvist kort), deploy, suspension, unsuspend, opsigelse, gen-deploy | 10 fulde gennemløb; 2 med fejl-injektion (betaling fejler midt i deploy → tenant-tilstand korrekt) |
| 1b | K8s-deploy, suspension (skala-til-0 + PVC bevaret), unsuspend, opdatering (ny version), rollback, undeploy, **restore af én tenant** | 10 gennemløb pr. scenarium; restore-test dokumenteret i runbook |
| 2 | Canary-rollout (stratificeret + rotation), DNS-automatik, backup/restore pr. plan (standard + premium) | Canary gennemført med realt billeder; restore-test pr. plan |
| 3 | Belastning ved 100+ tenants; failing tenant-isolation (NetworkPolicy-verifikation) | Ingen cross-tenant-adgang (netværkstest) |

Tester: udvikler + en "rigtig" kunde (intern betatestbruger) i fase 2.

## 6. Risici og beslutninger

### 6.1 Escape hatch — hvornår ville vi patche SellYourSaaS?

Princippet "vi patcher aldrig" gælder som udgangspunkt, men tre undtagelser er forudset:

1. **Sikkerhedshul i SellYourSaaS/Dolibarr**: vi patcher straks lokalt (eget fork), rapporterer til upstream og vender tilbage til upstream, når rettelsen er udgivet. SLA over for kunder: sikkerhedspatches ruller inden for 24 timer.
2. **Manglende funktion**: først forsøges løst i package-scripts (99 % af tilfælde); kun hvis det er umuligt (fx ny remote action-type), foreslås funktionen upstream (PR). Egen fork er sidste udvej.
3. **Protokolaendring upstream**: vores scripts kan bryde, hvis DoliCloud ændrer remote-action-protokollen. Opdagelse: **CI-test af scripts mod en mock-agent** (simulerer SellYourSaaS' kald) kører ved hver opdatering af SellYourSaaS i dev-instansen.

- **SellYourSaaS-agenten forventer vhost/DNS/health-mønstre** — vores Helm-chart skal give agenten noget at overvåge (Ingress-URL med health-endepunkt). Defineres i package-konfigurationen.
- **K8s er dyrere pr. instans end native** — accepteret for Dolibarr-ERP pga. sikkerhedskrav; PIM og lignende køres native for at holde omkostningerne nede.
- **GPL-bemærkning**: server-side-brug udløser ikke udleveringspligt; hvis modulet distribueres til kunder (on-prem), udløses GPL's distributionspligt. Vores egne shell-scripts og Helm-charts er egen kode (ikke afledt af modulet) og er dermed ikke GPL-smittede — kun modulet selv er.
- **Én primær vedligeholder upstream** (DoliCloud) — accepteret, netop fordi vi ikke patcher: versionsfrys er ikke nødvendig; en **dev-instans kører altid nyeste SellYourSaaS**, og opdateringer testes dér først (se §5, fase 1a punkt 3).
- **Dolibarr-webhooks er ikke pålidelige** — periodisk polling er en fast del af designet.
