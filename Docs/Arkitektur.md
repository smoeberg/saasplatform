# saasplatform — Arkitektur til SaaS-platform

> Status: rev. 6 (2026-09-25). Besluttet model: **SellYourSaaS forbliver uændret** (frit opdaterbart), to deployment-typer i produktion fra dag ét (native + Kubernetes via package-scripts). Kubernetes-operator/CRD udskudt, indtil antallet af container-tenants vokser.
>
> Rev. 6: gen-deploy-regler, omkostningsfodnote, migrerings-canary, skalerings-triggere, teknologi-beslutninger (DNS, S3, MariaDB, k3s, Traefik), fase 1b/1c-opdeling, fork-disciplin, CI-testniveauer, failure modes og tenant-migration.
>
> Rev. 5: cert-manager/suspension simplificeret, DB-rollback-semantik for Dolibarr-opdateringer, instance↔namespace-mapping, secrets-flow, DNS-detajler og omkostningsmodel tilføjet. Egne Dolibarr-moduler (bankconnect, dk-compliance) indgår i package-definitionen.

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

- `sources`: **vores egne Dolibarr-moduler** (fx dolibarr-bankconnect, dolibarr-dk-compliance) og custom-config-templates — pakket ind i imaget via CI eller leveret via `config-templates` i package-definitionen. Egen kode = ikke GPL-smittet (se §6). Selve sources installerer IKKE på runneren (imaget findes allerede i GHCR); modulerne indgår i image-buildet.
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
- **cert-manager**: ingen særbehandling. cert-manager's HTTP-01-solver opretter sin egen midlertidige pod + service + Ingress-regel og er ikke afhængig af tenantens app-pods — fornyelse virker, så længe Ingress-ressourcen og cert-manager lever. Verificeres eksplicit i fase 1b (test: suspender tenant → forvent fuldført fornyelse); hvis testen fejler, genindføres en minimal ACME-rute som kompensationslogik.
- **Retention-tælling**: 90 dage tæller **fra suspension** (ikke fra opsigelse). Varsling til kunden sker fra kundecenteret (SellYourSaaS' dunning-e-mails), retention er en plan-parameter.
- **Genbetaling under retention**: unsuspend er mulig indtil dag 90 (betaling genoptager instansen). Efter dag 90 slettes data — genoptagelse kræver restore fra backup (hvis inden for backup-retention) eller ny provisionering.

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

### 3.3.1 Instance↔namespace-mapping og secrets-flow

**Mapping (eksplicit, stabilt):**
- `k8s_namespace` og `helm_release` gemmes som **extrafields på Dolibarr-kontrakten** ved første deploy.
- Scripts er **deterministiske ud fra extrafieldet** (ikke ud fra contract-id alene): `NS=$(extraparam k8s_namespace)`.
- **Gen-deploy-regler**:
  - **Tomt extrafield** (kontrakt fra før K8s-pakken): scriptet genererer `tenant-{contract-id}` deterministisk og skriver det til extrafieldet.
  - **Manuel override af extrafield**: scriptet **respekterer** værdien, men logger en advarsel, hvis den ikke matcher `tenant-{contract-id}`.
  - **Genbrug af kontrakt**: kun acceptabelt, hvis PVC'er og secrets også er slettet. Eksplicit procedure: undeploy → slet namespace (inkl. PVC'er) → slet extrafield → først derefter kan kontrakten genbruges til en ny tenant.

**Secrets-flow (fase 1):**
1. Runneren genererer secrets lokalt (DB-password, app-secrets) ved første deploy.
2. SealedSecret oprettes via `kubeseal` og apply'es — **klartekst slettes straks** (genereres aldrig gemt på runneren).
3. Password-reset fra SellYourSaaS-admin: runner genererer ny secret → ny SealedSecret → `helm upgrade` → restart af pod.

### 3.3.2 Omkostningsmodel pr. Dolibarr-tenant (estimat, fase 1)

| Komponent | Estimat pr. tenant/måned |
|---|---|
| k3s-node-andel (CPU/RAM) | ~3-5 USD |
| MariaDB StatefulSet (PVC + RAM) | ~3-6 USD |
| Backup-lagring (S3, 7/30 dage) | ~0,5-2 USD |
| Runner (delt, ~20 USD pr. ~100 tenants) | ~0,2 USD |
| **I alt** | **~7-13 USD pr. tenant** |

Ved >50 tenants: overvej dedikeret MariaDB-operator eller (ved Postgres-skift) CloudNativePG for ensartet backup/restore. Ved >100: revurder delt DB med schema-isolation.

> **Fodnote**: Estimatet dækker **infrastruktur** (compute, storage, backup, delt runner-andel). Antagelser: MariaDB-PVC 10 GB pr. tenant (vokser med brug), backup-lagring pr. tenant på delt S3 (omkostning skalerer med samlet datamængde). **Egress-trafik, arbejdstid og support er ikke inkluderet** — egress kan blive betydelig ved tenants med høj trafik og skal overvåges fra fase 2.

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

- Nyt image i GHCR via CI → ny package-version i SellYourSaaS. **Versionsstyring**: image-tag = package-version, fx `ghcr.io/smoeberg/dolibarr-tenant:{package-version}` — deployment-scriptet resolver imaget ud fra den version, SellYourSaaS angiver.
- Udrulning i grupper: canary → 30–60 min. overvågning → udrulning til alle.
- **Canary-algoritme (præciseret)**:
  - Tenants grupperes pr. strata (plan × deployment-server).
  - Inden for hvert stratum: tenants sorteres pr. kontrakt-id; **rotationsindeks gemmes i Dolibarr** (fx i en extrafield); næste canary = indeks mod N, derefter indeks+1 osv.
  - Med 10 tenants og 5–10 % canary er der reelt 1 tenant pr. gang — rotationen sikrer, at alle gennemgår canary over tid (ingen kunde er permanent "kanin").
  - **Opt-out er en plan-parameter**: premium-kunder kan fravælge canary (de rammes kun af promoted-versioner).
- Fail-closed; rollback pr. tenant.
- **Rollback af Dolibarr-opdateringer (vigtig undtagelse)**: for Dolibarr-tenants er en opdatering ofte en **DB-migrering**, ikke kun et nyt image. Derfor:
  1. **DB-snapshot tages lige før migrering** (adskilt fra natlig backup) — køres af deploy-scriptet for Dolibarr-pakken (fx `mysqldump --single-transaction` → S3, tag `pre-migration-{version}`).
  2. Hvis opdateringen fejler **efter** migrering: rollback = gendan pre-migration-snapshot + sæt tidligere image-version. Ingen automatisk migration-down (Dolibarr understøtter det ikke sikkert).
  3. **Migrerings-canary-regel**: DB-migrerende versioner er **altid canary** (de er de risikable), men med **eksplicit pre-migration-snapshot pr. canary-tenant** — så fejl opdages på én tenant, før alle rammes.
  4. **Canary-vindue for migrerende versioner**: baseres på migreringsvarighed — vinduet = maks. (observed migrationsvarighed × 3, 30 min.). Hvis migreringen tager 30 min. på den største tenant, er vinduet 90 min.
  5. **S3-afhængighed**: rollback forudsætter tilgængelig S3. Hvis S3 er nede, fail-closes opdateringen (ingen migrering startes, før snapshot er verificeret uploadet — checksum + HEAD-objekt). S3 er dermed en kritisk afhængighed for opdateringsflowet; SLA dokumenteres pr. leverandør (se §4).
  6. Testet i fase 1b: opdater med migrering → fejlsimulér efter migrering → gendan snapshot + tidligere version → verificér funktionalitet.
- Native apps opdateres via SellYourSaaS' indbyggede `master_redeploy_instances`-mønster (batch + canary).

### 3.6 Observability og skaleringsmål

- Mål: **10 tenants i fase 1, 100+ i fase 2** (K8s), plus native-tenants i betydeligt højere antal (native er billigt; realistisk mål er fx **1000 native + 100 K8s** i fase 3, ikke 1000 K8s).
- Loki + Prometheus/Grafana; labels (`tenant_id`) — ikke separate instanser pr. tenant.
- **Skalerings-triggere (konkrete metrics, ikke tenant-antal)**:
  - **Loki**: revurderes ved p99 query-latency > 2 s i Grafana (foreløbigt estimat ~200 tenants; verificeres ved ~100).
  - **Prometheus**: revurderes ved aktive time-series > 1 M (per-tenant-labels reduceres først, derefter sharding).
  - **k3s-cluster**: revurderes ved > 500 pods i clusteret eller > 80 % node-RAM-udnyttelse; Capsule/vCluster først ved behov for multi-tenant-hardware-isolation.
- Dashboard pr. tenant: health via tenant-URL + SellYourSaaS' supervision.
- K8s-operator/CRD udskudt: Helm + cron-controllere er tilstrækkeligt til 10–50 tenants. Beslutningen genbesøges, når antallet af Dolibarr-tenants overstiger ~50.

## 4. Teknologistak

| Lag | Valg | Begrundelse |
|---|---|---|
| Management plane | SellYourSaaS (uændret Dolibarr-modul) | gennemtestet; gratis opdateringer |
| K8s-runner | Dedikeret VM **uden for** clusteret (kubectl + helm + kubeconfig) | Nemmere at drifte/rotere kubeconfig; angrebflade uden for clusteret (se §3.7) |
| DNS | **Cloudflare API** (A/CNAME pr. tenant via deploy-scriptet) | Billigt, API-drevet, propagation skalerer godt; script-kald er trivielle |
| Dataplane (ERP) | k3s, Traefik, cert-manager, sealed-secrets, tenant-DB | Strikt isolation pr. tenant |
| Dataplane (PIM) | SellYourSaaS native | Billigt, gennemprøvet, moderat risiko |
| Observability | Prometheus + Grafana + Loki | Standard, open source |
| Registry | GHCR | Allerede på GitHub |
| S3-kompatibel storage | **Wasabi** (alternativ: MinIO on-prem) | Lav pris pr. TB, ingen egress-gebyrer; Velero-kompatibel; SLA-dokumenteret (kritisk afhængighed, se §3.5) |
| MariaDB | **MariaDB 11.4 LTS** (i tenant-Stat efulSet) | LTS-support til 2029; Dolibarr-kompatibel; opgraderingsvej: MariaDB-operator i fase 3 |
| k3s | **Seneste stable minor** (fase 1: k3s v1.31+) | Nem opgradering (single binary + `k3s-killall` undgåes; opgradering pr. node); pinned version i IaC |
| Ingress-controller | **Traefik** (k3s-default) | Kommer med k3s som standard — ingen ekstra installation; CRD-baseret routing passer til Helm-charts. Nginx vurderes kun, hvis Traefik-showstoppers opstår |

## 5. Implementeringsfaser

**Fase 1a — forretningsflowet (uge 1–3)**
1. Installér Dolibarr + SellYourSaaS (master + 1 native deployment-server) i dev; gennemfør: registrering → deploy (native) → betaling → suspension.
2. Deployér PIM som første native package; verificér hele flowet med PIM.
3. **Dev-instans af SellYourSaaS kører altid nyeste version** — brud opdages tidligt, før produktion rammes.

**Fase 1b — K8s-grundintegration (uge 3–5): deploy/suspend/unsuspend/undeploy**
4. Sæt k3s-cluster op (Traefik, cert-manager, sealed-secrets) + K8s-runner (VM, §3.7) med kubectl/helm/kubeconfig.
5. Byg "kubernetes"-package til Dolibarr: Helm-chart (namespace, DB, Ingress, cert-manager) + 8 shell-scripts til de 8 remote actions. Indbyggede Dolibarr-moduler (bankconnect, dk-compliance) med i image-buildet.
6. **DNS-automatisering her** — provider: **Cloudflare** (besluttet, se §4); deploy-scriptet: opret A/CNAME-record, vent på propagation (TTL 300, max 10 min.) før health-check; undeploy-scriptet: slet record automatisk.
7. Verificér flowet end-to-end: ny testkunde → Helm-deploy → fakturering → suspension → undeploy.
8. Exit-kriterier: cert-manager-fornyelse under suspension verificeret; proto kol-test (CI-niveau 1) grøn.

**Fase 1c — Livscyklus og gendannelse (uge 5–8): opdatering/rollback/restore**
9. **Rollback efter fejlet DB-migrering** testet (se §3.5) — fejlsimulering efter migrering, snapshot-gendannelse, funktionsverifikation.
10. **Testet restore af én tenant** (runbook §3.3) — exit-kriterium.
11. Secrets-flow verificeret end-to-end (SealedSecret + password-reset via admin).
12. Integrations-test (CI-niveau 2) grøn: alle 8 actions mod rigtig K8s i CI, nightly.

**Fase 2 — produktion (uge 6–12)**
9. Produktionsmiljø for begge deployment-typer; Velero + natlig DB-dump.
10. Canary-rollout-rutine til opdateringer; dashboards og alerts.

**Fase 3 — skalering**
11. Revurdering af operator/CRD ved ~50 Dolibarr-tenants; reseller-netværk; external-secrets.

### 5.1 Testmatrix og exit-kriterier

| Fase | Scenarier | Exit-kriterium |
|---|---|---|
| 1a | Registrering, betaling (godkendt + afvist kort), deploy, suspension, unsuspend, opsigelse, gen-deploy | 10 fulde gennemløb; 2 med fejl-injektion (betaling fejler midt i deploy → tenant-tilstand korrekt) |
| 1b | K8s-deploy, suspension (skala-til-0 + PVC bevaret), unsuspend, undeploy, cert-fornyelse under suspension | 10 gennemløb pr. scenarium; protokol-test (CI-niveau 1) grøn |
| 1c | Opdatering (ny version), **rollback efter fejlet DB-migrering**, **restore af én tenant**, secrets-flow (klartekst slettes straks) | 10 gennemløb pr. scenarium; restore dokumenteret i runbook; integrations-test (CI-niveau 2) grøn |
| 2 | Canary-rollout (stratificeret + rotation), DNS-automatik, backup/restore pr. plan (standard + premium) | Canary gennemført med realt billeder; restore-test pr. plan |
| 2 (fejl-injektion) | Betaling fejler midt i deploy; **runner-nedbrud** (kill -9 på runner); **DNS-timeout** (Cloudflare API svarer ikke); **cert-manager-fejl** ( fejlet Challenge) | Tenant-tilstand korrekt efter hver fejl; alarm udløses; ingen halvfærdig instans |
| 3 | Belastning ved 100+ tenants; failing tenant-isolation (NetworkPolicy-verifikation) | Ingen cross-tenant-adgang (netværkstest) |

Tester: udvikler + en "rigtig" kunde (intern betatestbruger) i fase 2.

## 6. Risici og beslutninger

### 6.1 Escape hatch — hvornår ville vi patche SellYourSaaS?

Princippet "vi patcher aldrig" gælder som udgangspunkt, men tre undtagelser er forudset:

1. **Sikkerhedshul i SellYourSaaS/Dolibarr**: vi patcher straks lokalt (eget fork), rapporterer til upstream og vender tilbage til upstream, når rettelsen er udgivet. SLA: sikkerhedspatch ruller inden for 24 timer **fra opdagelse**, for alle kunder (ikke kun premium).
2. **Manglende funktion**: først forsøges løst i package-scripts (99 % af tilfælde); kun hvis det er umuligt (fx ny remote action-type), foreslås funktionen upstream (PR). Egen fork er sidste udvej.
3. **Protokolaendring upstream**: vores scripts kan bryde, hvis DoliCloud ændrer remote-action-protokollen. Opdagelse: CI-test (niveau 1, se nedenfor) kører ved hver commit.

**Fork-disciplin (konkret):**
- Fork er en **midlertidig branch** i eget repo, aldrig en permanent tilstand.
- Patch holdes som **patch-fil** i eget repo (ikke Git-submodule) — anvendes over upstream-tarball i CI.
- **Rebase mod upstream ugentligt** (automatisk cron-job, der forsøger rebase og alarmerer ved konflikt).
- **Fork droppes inden for 30 dage** efter upstream-release med tilsvarende rettelse.

**CI-testniveauer:**
- **Niveau 1 — protokol-test** (mock-agent, ved hver commit): simulerer SellYourSaaS' kald af de 8 remote actions; verificerer exit-koder og argumenter. Fanger protokolbrud.
- **Niveau 2 — integrations-test** (rigtig K8s via k3d, nightly): verificerer at scripts efterlader K8s i forventet tilstand (namespace, replicas, PVC'er, secrets). Fanger adfærdsregressioner.

### 6.2 Failure modes — de mest sandsynlige fejlscenarier

| Scenario | Opdagelse | Håndtering |
|---|---|---|
| Deploy fejler halvvejs (netværk, kvote overskredet) | Fail-closed exit-kode → agenten rapporterer | Admin re-kører deploy (idempotent); kunde ser status i myaccount |
| Health-check fejler i > 30 min. | SellYourSaaS supervision → alarm | On-call eskalation; diagnose via dashboards; evt. rollback til sidst kendt god version |
| Tenant-DB korrupt | Backup-verifikation (natlig test-restore af sample) | Restore fra seneste snapshot; kunden kontaktes af support |
| Runner-nedbrud | Heartbeat udebliver → alarm | Re-provisionér runner fra IaC; gen-kør fejlede actions (idempotente) |
| S3 ikke tilgængelig | HEAD-check før migrering (fail-closed) | Opdatering afvises; ingen migrering startet; S3 SLA check |
| cert-manager-fejl (Challenge fejler) | cert-manager-events + alarm | Manuelt: tjek DNS/Ingress; fallback: minimal ACME-rute (se §3.3) |
| K8s-cluster-nedbrud | Node-exporter → alarm | Velero-restore af tenants til nyt cluster (runbook); RTO ~1-4 timer |
| Fakturering-dublet (Dolibarr-batch kører to gange) | SellYourSaaS-kontrol (idempotent batch) | Manuel kreditering; dokumenteres pr. hændelse |

### 6.3 Tenant-migration mellem deployment-servere

| Migration | Understøttet? | Metode |
|---|---|---|
| Native → anden native server | Fase 2 | SellYourSaaS' indbyggede flytning (dump + redeploy på ny server + DNS-cutover) |
| K8s → andet cluster | Fase 3 (Ved behov) | Velero-restore til nyt cluster + DNS-cutover; nedetid ~ 30 min |
| Native → K8s (ændrede sikkerhedskrav) | **Manuelt arbejde med nedetid** | Dump + Helm-deploy + import; planlægges med kunden; ikke automatisk |

Det sidste er en bevidst begrænsning: native→K8s er en arkitektur-migration, ikke en driftsoperation. Kommunikeres til kunden ved opgradering.

- **SellYourSaaS-agenten forventer vhost/DNS/health-mønstre** — vores Helm-chart skal give agenten noget at overvåge (Ingress-URL med health-endepunkt). Defineres i package-konfigurationen.
- **K8s er dyrere pr. instans end native** — accepteret for Dolibarr-ERP pga. sikkerhedskrav; PIM og lignende køres native for at holde omkostningerne nede.
- **GPL-bemærkning**: server-side-brug udløser ikke udleveringspligt; hvis modulet distribueres til kunder (on-prem), udløses GPL's distributionspligt. Vores egne shell-scripts og Helm-charts er egen kode (ikke afledt af modulet) og er dermed ikke GPL-smittede — kun modulet selv er. **Krav**: egne scripts/charts må **ikke** inkludere GPL-kode eller kalde GPL-biblioteker, der smitter; holdes i separat repo (smoeberg/saasplatform), så det er verificerbart.
- **Én primær vedligeholder upstream** (DoliCloud) — accepteret, netop fordi vi ikke patcher: versionsfrys er ikke nødvendig; en **dev-instans kører altid nyeste SellYourSaaS**, og opdateringer testes dér først (se §5, fase 1a punkt 3).
- **Dolibarr-webhooks er ikke pålidelige** — periodisk polling er en fast del af designet.
