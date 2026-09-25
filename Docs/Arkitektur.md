# saasplatform — Arkitektur til SaaS-platform

## 1. Formål og grundidé

saasplatform er en generel platform til drift af SaaS-forretninger:

- **Software leveres i containere** og rulles automatisk ud per kunde.
- **Dolibarr er "single source of truth"** for kunder, abonnementer, økonomi og support.
- Platformen håndterer **onboarding, opdatering, suspension, backup og support** — 100 % automatiseret fra ordre til opsigelse.

Fundamentet er et hybrid-design: vi genbruger det gennemtestede forretningslag fra [SellYourSaas](https://github.com/DoliCloud/sellyoursaas) (DoliCloud, open source, i produktion hos dolicloud.com og glpi-network.cloud) og erstatter dets data plane (Apache/PHP/chroot per Unix-bruger) med et Kubernetes-baseret container-dataplane.

## 2. Arkitekturprincipper

1. **Dolibarr er en adapter, ikke en afhængighed.** Alt Dolibarr-specifikt (REST API, webhooks, eventformater) ligger i én adapter. Platformens kerne taler et generisk sprog: *tenant → produkt, plan, version, ønsketilstand*. Platformen kan dermed sælges og kobles til ethvert ERP.
2. **Én kilde til sandhed per datatype.** Dolibarr ejer kunder, kontrakter, fakturering og tickets. Platformens kerne gemmer kun tenant-lifecycle-tilstand (status, version, ønsketilstand). Kundedata må aldrig duplikeres.
3. **Kun Kubernetes-provisionering.** Provisioneringslogik skrives én gang og målrettes K8s-API'et (k3s i dev og prod). Docker Compose/Swarm bruges kun til lokal udvikling af selve produkterne.
4. **Idempotent provisionering via operator-mønsteret.** Ønsketilstand erklæres som Kubernetes-CR; operatoren reconciler uafbrudt. Kubernetes API er kilden til status.
5. **Fail-closed.** Udrulninger og ændringer rammer kun produktion, når health-checks er grønne; provisioneringsfejl stopper flowet frem for at efterlade halvfærdige instanser.

## 3. Logisk arkitektur

```
                    Dolibarr (ERP/CRM: kunder, kontrakter, fakturaer, tickets)
                        │  SellYourSaas-modul: packages, services, myaccount,
                        │  Stripe/SEPA-betaling, suspension, anti-abuse
                        │  (webhooks + REST-polling som sikkerhedsnet)
                        ▼
              ┌──────────────────────┐
              │  Dolibarr-adapter /  │   ← det eneste Dolibarr-bevidste lag
              │  deployment-agent    │     (SellYourSaaS' remote-action-protokol)
              └─────────┬────────────┘
                        ▼
              ┌──────────────────────┐
              │  Tenant Controller   │   ← platformens egen, genbrugelige kerne
              │  (lifecycle-motor)   │     (tenant state, canary-rollouts, audit)
              └─────────┬────────────┘
                        ▼
              ┌──────────────────────┐
              │  K8s Operator        │   ← reconciler TenantInstance-CR
              └─────────┬────────────┘
                        ▼
    ┌───────────────────────────────────────────────┐
    │  Kubernetes (data plane) — 1 namespace/tenant │
    │  Deployment/StatefulSet · Service · Ingress · │
    │  PVC · Secrets (sealed/external-secrets) ·    │
    │  NetworkPolicy · ResourceQuota ·              │
    │  produktets Helm-chart                        │
    └───────────────────────────────────────────────┘
    Support: dashboard (CRD-status) · Loki · Prometheus/Grafana
    Event-bus (NATS): operator-hændelser → AutoHeal (fase 2)
```

### 3.1 SellYourSaas' rolle (management plane)

Fra SellYourSaas genbruges uændret:

- **Packages-modellen**: et *Package* definerer produktet (sources, config-templates med variabler som `__APPDOMAIN__`/`__DBNAME__`, SQL-after-deploy, cron-templates, shell-after-deploy). Oversættes til: sources → container-image, config-template → ConfigMap/Secret, SQL-after-deploy → init-job, shell-after-deploy → postStart-hook/job.
- **Services-modellen**: en *Service* (type Application) kobler pakken til abonnement, pris, tilvalg og metrics (antal beregnes via BASH/SQL/PHP-formler — fx "pris pr. bruger").
- **Kundecenter (myaccount)**: register.php, login, instans-oversigt, fakturering, tickets.
- **Betaling**: Stripe (SCA) og SEPA, automatisk fakturering, spærring ved manglende betaling, rykkerprocedurer.
- **Support og anti-abuse**: helpdesk, blacklists, kvoter, fail2ban-principper.
- **Reseller-netværk** (kan aktiveres senere).

### 3.2 Ny dataplane-type: "Kubernetes deployment server"

I SellYourSaaS sender masteren 8 remote actions (deploy, deployall, undeploy, undeployall, suspend, unsuspend, refresh, recreateauthorizedkeys) til deployment-serverens agent på port 8080. Vi tilføjer en ny deployment-server-type, **"kubernetes"**, hvor agenten i stedet for at køre shell-scripts oversætter handlingerne til K8s-API-kald:

| SellYourSaaS action | K8s-operation |
|---|---|
| deploy/deployall | opret namespace + ResourceQuota + NetworkPolicy; generér Secrets; Helm-installation af produktchart; Ingress + cert-manager (TLS); DNS-record via API |
| undeploy/undeployall | Helm-uninstall → sletning af namespace (finalizers), backup før sletning |
| suspend/unsuspend | sæt Ingress til "suspended"-vhost (kundens egen kontekst bevares), read-only |
| refresh | genanvend ønsketilstand (reconcile) |
| recreateauthorizedkeys | roter platformens adgangsoplysninger til tenant |

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
  options: {storageGb: 10, users: 5}
  suspended: false
status:
  phase: provisioning          # provisioning | ready | suspended | failed | deleted
  observedGeneration: 3
  health: green
  lastMessage: "Helm release 23.0.1 deployed"
  conditions: [...]
```

Operatoren (Go + Operator SDK/kubebuilder) reconciler uafbrudt: CR er ønsketilstanden, Kubernetes er tilstandsmotoren.

### 3.4 Opdateringsflow

- Nyt image i GHCR via CI → ny package-version i SellYourSaaS.
- Tenant Controller styrer rollout i grupper: canary (5–10 % af tenants) → 30–60 min. overvågning (health via CRD-status + Prometheus) → promover til alle. Styring sker i controlleren, ikke pr. Git-commit pr. tenant.
- Fail-closed: ny version promoveres kun, hvis canary-gruppen er grøn.
- Rul tilbage = sæt tidligere version i CR; operatoren reconciler tilbage.

### 3.5 Support-lag

- Dashboard pr. tenant: CRD-status, version, health, seneste hændelser — direkte fra K8s-API, ingen egen status-DB.
- Logs: Loki; metrics: Prometheus/Grafana, mærket pr. tenant-namespace.
- Adgang til tenant-data sker kun via platformen med audit-log — aldrig direkte adgang til tenant-containere.
- Tickets forbliver i Dolibarr; platformen linker ticket → tenant og viser health.

### 3.6 Sikkerhed og backup

- Namespace + NetworkPolicy + ResourceQuota pr. tenant (hård isolation).
- Secrets via sealed-secrets/external-secrets; TLS overalt via cert-manager; audit-log af alle administrative handlinger.
- Backup: Velero pr. tenant-namespace + natlige DB-dumps til S3-kompatibel storage (SellYourSaaS' backup-disciplin videreføres).
- Anti-abuse: genbrug af SellYourSaaS' blacklist- og quota-systemer på tilmeldingsniveau.

## 4. Teknologisk stak

| Lag | Valg | Begrundelse |
|---|---|---|
| Management plane | SellYourSaas (Dolibarr-modul) | Battle-tested forretningslag; daglig drift hos DoliCloud |
| Adapter/agent (K8s-target) | PHP (SellYourSaaS-agent) + Go-klient | Understøtter eksisterende remote-action-protokol |
| Tenant Controller | Go (Operator SDK/kubebuilder) | Idempotent reconcile; standard-økosystem |
| CRD | `TenantInstance` | K8s fungerer som tilstandsmotor |
| Produkt-pakkering | Helm charts pr. produkt | Genbrugelig, versioneret |
| Event-bus | NATS | Letvægt; krog til AutoHeal i fase 2 |
| Observability | Prometheus + Grafana + Loki | Standard, open source |
| Registry | GHCR | Allerede på GitHub |
| Ingress/TLS | Traefik (eller Nginx) + cert-manager | Dynamisk routing pr. tenant-domæne |
| Klynge | k3s | Enkel, stabil, let at drifte on-prem |

## 5. Implementeringsfaser

**Fase 1 — fundament (uge 1–4)**
1. Installér SellYourSaaS (master + 1 deployment-server) i dev; gennemfør hele flowet: registrering → deploy → betaling → suspension.
2. Definér `TenantInstance`-CRD (spec + status + phases) og Dolibarr-event-kontrakten (ny ordre, planændring, opsigelse, betaling/modbetaling) med webhook-signering.
3. Byg operatoren (skeleton) + Helm-chart til ét produkt; k3s-dev-klynge med Traefik, cert-manager, sealed-secrets.

**Fase 2 — produktionsmodning (uge 5–10)**
4. Ny deployment-server-type "kubernetes" i SellYourSaaS; agent implementerer de 8 remote actions mod K8s.
5. Canary-rollout-controller i Tenant Controller; dashboards, Loki/Prometheus, Velero-backup.
6. NATS-event-bus + logning af alle hændelser (AutoHeal-implementering udskydes).

**Fase 3 — skalering**
7. Support for flere produkter (flere packages/charts), reseller-netværk, AutoHeal, DNS-automatisering pr. tenant.

## 6. Risici og beslutninger

- **SellYourSaaS deployerer ikke containere som standard** — det er et bevidst kompromis for at holde omkostningerne nede (dokumentationen angiver ≥10x lavere omkostninger end container-løsninger). Vores K8s-agent er derfor et selvbygget tillæg: hold ændringer i en separat agent-type, og bidrag gerne tilbage upstream (GPL: server-side-brug udløser ikke udleveringspligt, men ændringer vi deler, skal deles).
- **Én hovedvedligeholder upstream** (DoliCloud) — planlæg versionsfrys af SellYourSaaS-modulet og egne patches i eget repo.
- **Dolibarr-webhooks er ikke pålidelige** — periodisk polling er en fast del af designet, ikke en feature til "senere".
- **AutoHeal nu = overengineering** — byg event-krogen, men udskyd automatiseringen.
- **Omkostninger**: K8s-dataplane er dyrere pr. instans end SellYourSaaS' native-mode; hvis de første produkter er PHP-apps, kan de i en overgangsperiode køre på SellYourSaaS' native deployment-servere, mens K8s-tilgangen modnes. Én platform, to deployment-typer.
