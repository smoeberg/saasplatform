# saasplatform — Arkitektur til SaaS-platform

> Status: Besluttet. Hybrid-design vedtaget: SellYourSaas som management plane, Kubernetes som data plane. Dokumentet inkluderer beslutninger fra arkitekturgennemgangen (2026-09-25).

## 1. Formål og grundidé

saasplatform er en generel platform til drift af SaaS-forretninger:

- **Software leveres i containere** og udrulles automatisk pr. kunde.
- **Dolibarr er "source of truth"** for kunder, abonnementer, økonomi og support.
- Platformen håndterer **onboarding, opdatering, suspension, backup og support** — 100 % automatiseret fra ordre til opsigelse.

Fundamentet er et hybrid-design: Vi genbruger det gennemtestede forretningslag fra [SellYourSaas](https://github.com/DoliCloud/sellyoursaas) (DoliCloud, open source, i produktion hos dolicloud.com og glpi-network.cloud) og erstatter dets data plane (Apache/PHP/chroot pr. Unix-bruger) med et Kubernetes-baseret container-dataplane. SellYourSaaS deployer som udgangspunkt ikke containere — derfor er K8s-agenten et selvbygget tillæg og ikke blot en konfigurationsændring.

## 2. Arkitekturprincipper

1. **Dolibarr er en adapter, ikke en afhængighed.** Alt Dolibarr-specifikt (REST API, webhooks, eventformater) er samlet i én adapter. Platformens kerne benytter et generisk sprog: *tenant → produkt, plan, version, ønsketilstand*. Platformen kan dermed sælges og kobles til ethvert ERP-system.
2. **Én kilde til sandhed pr. datatype.** Dolibarr ejer kunder, kontrakter, fakturering og tickets. Platformens kerne gemmer kun tenant-lifecycle-tilstand (status, version, ønsketilstand). Kundedata må aldrig duplikeres.
3. **Kun Kubernetes-provisionering.** Provisioneringslogik skrives én gang og målrettes K8s-API'et (k3s i dev og prod). Docker Compose/Swarm bruges kun til lokal udvikling af selve produkterne.
4. **Idempotent provisionering via operator-mønsteret.** Ønsketilstanden deklareres som en Kubernetes-CR; operatoren sørger for kontinuerlig reconciliation. Kubernetes API er kilden til status.
5. **Fail-closed.** Udrulninger og ændringer rammer kun produktion, når health-checks er grønne; fejl i provisioneringen stopper flowet frem for at efterlade halvfærdige instanser.

## 3. Logisk arkitektur

```
                    Dolibarr (ERP/CRM: kunder, kontrakter, fakturaer, tickets)
                        │  SellYourSaas-modul: packages, services, myaccount,
                        │  Stripe/SEPA-betaling, suspension, anti-abuse
                        │  (webhooks + REST-polling som sikkerhedsnet)
                        ▼
              ┌───────────────────────────────────┐
              │  Dolibarr-adapter /               │   ← det eneste Dolibarr-bevidste lag
              │  deployment-agent ("kubernetes")  │     (SellYourSaaS' remote-action-protokol,
              │                                   │      versioneret + kontrakt-testet i CI)
              └─────────┬─────────────────────────┘
                        ▼
              ┌───────────────────────────────────┐
              │  Tenant Controller                │   ← platformens egen, genbrugelige kerne
              │  (ÉN Go-binar, to reconcilers):  │     (delt RBAC + audit-log-strøm)
              │  1) lifecycle-reconciler (events) │     (canary-logikken læser/skriver
              │  2) CR-reconciler (idempotent)    │      TenantInstance-spec direkte)
              └─────────┬─────────────────────────┘
                        ▼
    ┌───────────────────────────────────────────────┐
    │  Kubernetes (data plane) — 1 namespace/tenant │
    │  Deployment/StatefulSet · Service · Ingress · │
    │  PVC · tenant-eget DB-StatefulSet · Secrets · │
    │  NetworkPolicy · ResourceQuota ·              │
    │  produktets Helm-chart                        │
    └───────────────────────────────────────────────┘
    Support: dashboard (CRD-status) · Loki · Prometheus/Grafana
    Event-bus (NATS): operator-hændelser → AutoHeal (fase 3)
```

### 3.1 SellYourSaas' rolle (management plane)

Fra SellYourSaas genbruges uændret:

- **Packages-modellen**: et *Package* definerer produktet (sources, config-templates med variabler som `__APPDOMAIN__`/`__DBNAME__`, SQL-after-deploy, cron-templates, shell-after-deploy). Oversættes til: sources → container-image, config-template → ConfigMap/Secret, SQL-after-deploy → init-job, shell-after-deploy → postStart-hook/job.
- **Services-modellen**: en *Service* (type Application) kobler pakken til abonnement, pris, tilvalg og metrics (antal beregnes via BASH/SQL/PHP-formler — fx "pris pr. bruger"). **Kvoter pr. kunde/IP/tidsinterval er en del af plan-definitionen**, ikke blot et plan-navn.
- **Kundecenter (myaccount)**: register.php, login, instans-oversigt, fakturering, tickets.
- **Betaling**: Stripe (SCA) og SEPA, automatisk fakturering, suspension ved manglende betaling, dunning.
- **Support og anti-abuse**: helpdesk, blacklists, kvoter.
- **Reseller-netværk**: kommission knyttet til betalte fakturaer — aktiveres, hvis platformen sælges via partnere.
- **Manuel admin-override**: deploy/suspend/undeploy og password-reset er et separat sæt handlinger ved siden af det automatiske event-drevne flow — det er en nødvendighed i praksis og skal være tænkt ind fra start.

### 3.2 Ny dataplane-type: "Kubernetes deployment server"

I SellYourSaaS sender masteren 8 remote actions (deploy, deployall, undeploy, undeployall, suspend, unsuspend, refresh, recreateauthorizedkeys) til deployment-serverens agent på port 8080. Vi tilføjer en ny deployment-server-type, **"kubernetes"**, hvor agenten i stedet for at køre shell-scripts oversætter actions til K8s-API-kald:

| SellYourSaaS action | K8s-operation |
|---|---|
| deploy/deployall | opret namespace + ResourceQuota + NetworkPolicy; generér Secrets; Helm-install af produktchart (inkl. tenant-specifikt DB-StatefulSet); Ingress + cert-manager (TLS); DNS-record via API |
| undeploy/undeployall | backup-dump → Helm-uninstall → sletning af namespace (finalizers); tilbagekald alle platformens legitimationsoplysninger til tenant |
| suspend/unsuspend | **skalering til nul** af tenant-workloads + Ingress blokeret med "suspended"-vhost; **PVC'er bevares**; CronJobs suspenderes; retention: data bevares i 90 dage, hvorefter de slettes (GDPR) — konfigurerbart pr. plan |
| refresh | genopret ønsket tilstand (reconcile) |
| recreateauthorizedkeys | roter platformens adgangsoplysninger til tenant; ved opsigelse: eksplicit revoke-action |

Protokol- og versionstyring: remote-action-kaldene bærer en **protokolversion**; agenter, der er bagud, afvises pænt (fail-closed); kontrakt-test adapter↔agent kører i CI mod en mock-server.

### 3.3 TenantInstance-CRD

```yaml
apiVersion: saasplatform.io/v1
kind: TenantInstance
metadata:
  name: tenant-usrA1B2C3
  namespace: tenant-instances
spec:
  tenantId: usrA1B2C3          # = SellYourSaaS contract id
  productRef: dolibarr         # package reference
  plan: standard               # service/plan fra Dolibarr
  version: "23.0.1"            # billedversion
  domain: kunde.mysaasdomain.com
  quota:                       # er en del af plan-definitionen
    users: 5
    storageGb: 10
  resellerRef: ""              # fyldes, hvis tenant er skabt via reseller
  suspended: false
status:
  phase: provisioning          # provisioning | ready | suspended | failed | deleted
  observedGeneration: 3
  health: green
  lastMessage: "Helm release 23.0.1 deployed"
  conditions: [...]
```

Operatoren (Go + Operator SDK/kubebuilder) reconciler kontinuerligt: CR er ønsketilstanden, og Kubernetes er tilstandsmotoren.

### 3.4 Database pr. tenant

Grundlæggende valg: **database pr. tenant** (StatefulSet i tenant-namespace, provisioneret via produktets Helm-chart). Dette sikrer hård isolation, uafhængig backup og forudsigelig ydelse; omkostningerne styres med ResourceQuota.

- Delt database med schema-isolation er eksplicit **ikke** tilgangen i fase 1 — det er kun relevant ved >1000 tenants eller meget små planer.
- Backup af DB: applikationsbevidste dumps (mysqldump/pg_dump) pr. tenant, ikke kun Velero-PVC.

### 3.5 Opdateringsflow

- Nyt image i GHCR via CI → ny package-version i SellYourSaaS.
- Tenant Controller (samme binære fil som operatoren) styrer rollout i grupper: canary (5–10 % af tenants) → 30–60 min. overvågning (health via CRD-status + Prometheus) → udrulning til alle. Styringen sker i controlleren og ikke via Git-commits pr. tenant.
- **Canary-udvælgelsen er stratificeret** (ikke tilfældig): mindst én tenant pr. plan og pr. deployment-server/region, roteret så canary-gruppen ikke altid består af de samme kunder. Rollback sker **pr. tenant** og ikke for hele gruppen.
- Fail-closed: ny version promoveres kun, hvis canary-gruppen er grøn.
- Rul tilbage = sæt tidligere version i CR; operatoren reconciler tilbage.

### 3.6 Support-lag

- Dashboard pr. tenant: CRD-status, version, health, seneste hændelser — direkte fra K8s-API, uden egen status-DB.
- Logs: Loki; metrics: Prometheus/Grafana, mærket pr. tenant-namespace.
- Adgang til tenant-data sker kun via platformen med audit-log — aldrig direkte i tenant-containere.
- Tickets forbliver i Dolibarr; platformen linker ticket → tenant og viser health.

### 3.7 Sikkerhed og backup

- Namespace + NetworkPolicy + ResourceQuota pr. tenant (stærk isolation).
- Secrets: **sealed-secrets i fase 1** (færre afhængigheder, k3s-venligt); external-secrets (Vault/KMS) vurderes i fase 3, når flere produkter kræver rotation.
- TLS overalt via cert-manager; audit-log af alle administrative handlinger.
- **Backup-politik pr. plan** (med samtidige snapshots, ikke forskudt):
  - Standard: daglig Velero (namespace) + natlig DB-dump, 7 dages retention.
  - Premium: daglig Velero + DB-dump + binlog-stream (point-in-time recovery), 30 dages retention.
  - Gendannelse af enkelt tenant: Velero-restore af namespace + indlæsning af tilhørende DB-dump via init-job.
- Anti-abuse: genbrug af SellYourSaaS' blacklist- og quota-systemer på tilmeldingsniveau.

### 3.8 Observability og skaleringsmål

- Mål: **10 tenants i fase 1, 100+ i fase 2, 1000+ i fase 3** — dimensioneringen følger heraf.
- Loki/Prometheus bruger labels (`tenant_id`) fremfor separate instanser pr. tenant; hvis 1000+ tenants kræver det, vurderes Capsule/vCluster før endelig beslutning.
- Namespaces forbliver isolationsgrænsen i K8s uanset tilgangen til observability.

## 4. Teknologisk stak

| Lag | Valg | Begrundelse |
|---|---|---|
| Management plane | SellYourSaas (Dolibarr-modul) | gennemtestet forretningslag; daglig drift hos DoliCloud |
| Adapter/agent (K8s-target) | SellYourSaaS-agent + Go-klient | understøtter eksisterende remote-action-protokol (versioneret) |
| Tenant Controller | ÉN Go-binær (Operator SDK/kubebuilder), to reconcilers | Idempotent reconcile; færre bevægelige dele i fase 1 |
| CRD | `TenantInstance` | K8s fungerer som tilstandsmotor |
| Produkt-pakkering | Helm charts pr. produkt | Genbrugelig, versioneret |
| Event-bus | NATS | Letvægt; mulighed for AutoHeal i fase 3 |
| Observability | Prometheus + Grafana + Loki | Standard, open source |
| Registry | GHCR | Allerede på GitHub |
| Ingress/TLS | Traefik + cert-manager | Traefiks CRD-baserede routing passer til operator-mønsteret; Nginx droppet for at undgå dobbeltkonfiguration |
| Klynge | k3s | Enkel, stabil, let at drifte on-prem |

## 5. Implementeringsfaser

**Fase 1a — validering af forretningsflowet (uge 1–3)**
1. Installér SellYourSaaS (master + 1 **native** deployment-server) i dev; gennemfør hele flowet: registrering → deploy (native) → betaling → suspension. Dette er et proof of concept for management-planen, ikke for containere.

**Fase 1b — validering af container-dataplanen (uge 3–6)**
2. Definér `TenantInstance`-CRD (spec + status + phases) og Dolibarr-event-kontrakten (ny ordre, planændring, opsigelse, betaling/modbetaling) med webhook-signing og protokolversion i kaldene (gamle agenter afvises høfligt; kontrakt-test i CI mod mock-server).
3. Byg operatoren (skeleton) + ét produkts Helm-chart (inkl. tenant-DB); k3s-dev-klynge med Traefik, cert-manager, sealed-secrets.

**Fase 2 — produktionsklar (uge 6–12)**
4. Ny deployment-server-type "kubernetes" i SellYourSaaS; agent implementerer de 8 remote actions mod K8s. Første K8s-tenant i produktion.
5. Canary-rollout-controller; dashboards, Loki/Prometheus, Velero-backup, DNS-automatik pr. tenant.
6. NATS-event-bus + log over alle hændelser (AutoHeal-implementering udskydes).

**Fase 3 — skalering**
7. Support for flere produkter (flere packages/charts), reseller-netværk, AutoHeal, external-secrets.
8. **Udfasning af native-mode**: deadline = 12 måneder efter første K8s-tenant i produktion. Migrering fra native → K8s: datadump + DNS-cutover med planlagt nedetid; tilbagemigrering fra K8s → native understøttes ikke.

## 6. Risici og beslutninger

- **SellYourSaaS deployer ikke containere som standard** — det er et bevidst kompromis af hensyn til omkostningerne (dokumentationen angiver ≥10x lavere omkostninger end container-løsninger). Vores K8s-agent er derfor et selvbygget tillæg: hold ændringer i en separat agent-type, og bidrag gerne tilbage upstream.
- **GPL-bemærkning**: brug på serversiden udløser ikke udleveringspligt; men hvis modulet distribueres til kunder (f.eks. on-prem), udløser det GPL's distributionspligt. Bidrag gerne ændringer tilbage.
- **Én hovedvedligeholder upstream** (DoliCloud) — planlæg versionsfrys af SellYourSaaS-modulet og egne patches i eget repo.
- **Dolibarr-webhooks er ikke pålidelige** — periodisk polling er en fast del af designet, ikke en feature til senere.
- **AutoHeal nu = overengineering** — byg event-krogen, men udskyd automatiseringen.
- **Omkostninger**: K8s-dataplane er dyrere pr. instans end SellYourSaaS' native-mode; hvis de første produkter er PHP-apps, kan de i en overgangsperiode køre på SellYourSaaS' native deployment-servere, mens K8s-tilgangen modnes. Én platform, to deployment-typer — men med en fastsat deadline (se fase 3.8).
