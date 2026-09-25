# Scripts — SellYourSaaS "kubernetes"-package remote actions

De 8 scripts til package-typen beskrevet i `Saasplatform_Arkitektur.md` §3.2. Alle
sourcer `lib.sh` som første linje og deler navnekonvention, logging og fejlhåndtering.

| Script | SellYourSaaS remote action | Formål |
|---|---|---|
| `beforedeploy.sh` | beforedeploy | Pre-flight: values-fil gyldig, RBAC ok |
| `afterdeploy.sh` | afterdeploy | `helm upgrade --install`, vent på healthz, statusartefakt |
| `beforeundeploy.sh` | beforeundeploy | Sikkerhedsdump af DB før nedlæggelse |
| `afterundeploy.sh` | afterundeploy | `helm uninstall` + slet namespace |
| `aftersuspend.sh` | aftersuspend | `helm upgrade --set suspended=true` |
| `afterunsuspend.sh` | afterunsuspend | `helm upgrade --set suspended=false` |
| `refresh.sh` | refresh | Re-konvergering — bruges også til opdatering/rollback |
| `cron.sh` | cron | Eksternt healthz-tjek af tenant-URL |

## Antagelser der SKAL verificeres, før dette køres mod en rigtig SellYourSaaS-installation

1. **Kaldskonvention**: scripts antages kaldt som `script.sh <contract-id>`. Hvis jeres
   SellYourSaaS-version i stedet eksporterer contract-id som miljøvariabel, ret
   `INSTANCE=...`-linjen i `lib.sh`.
2. **"Deployed"-artefaktet** i `afterdeploy.sh` er en antagelse (en statusfil under
   `$STATUS_DIR`). Den faktiske mekanisme SellYourSaaS-agenten bruger til at registrere
   en instans som deployed er ikke bekræftet endnu — match det her, når I ved det.
3. **DNS-skema** (`tenant_healthz_url` i `lib.sh`) antager `https://<contract-id>.<TENANT_DOMAIN>/healthz`.
   Ret `TENANT_DOMAIN` og evt. selve funktionen hvis jeres skema er anderledes.
4. **DB-pod-label**: `beforeundeploy.sh` forventer at DB-pod'en er labelet
   `app.kubernetes.io/component=db` — skal matche det, Helm-charten faktisk sætter.
5. **Helm-charten skal understøtte `.Values.suspended`** (bool). Når `true`: replicas=0,
   ingen CronJobs, Ingress peger på en "suspended"-side. Dette er endnu ikke bygget —
   det er den næste opgave (`Helm/erp-tenant`).

## Miljøvariabler (kan sættes i systemd-unit eller SellYourSaaS' agent-miljø)

- `KUBECONFIG` — sti til runnerens kubeconfig (default `/etc/saasplatform/kubeconfig`)
- `CHART_DIR` — sti til Helm-charten (default `/opt/saasplatform/Helm/erp-tenant`)
- `VALUES_DIR` — hvor SellYourSaaS' config-template render pr.-instans values-filer til
- `STATUS_DIR` — hvor scripts skriver statusartefakter
- `TENANT_DOMAIN` — domænet tenant-subdomæner ligger under
- `DUMP_DIR` — hvor pre-undeploy DB-dumps gemmes

## Ikke dækket her (bevidst)

- Runner-heartbeat (§3.7) — separat cron på selve K8s-runner-VM'en, ikke en del af
  package'ets 8 actions.
- NetworkPolicy/ResourceQuota — hører til i Helm-charten, ikke i disse scripts.
- DNS-automatisering (fase 1b, §5) — endnu et separat script/kald mod DNS-provider-API'et.
