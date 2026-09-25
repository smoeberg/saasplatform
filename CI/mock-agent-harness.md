# CI-harness: Mock-agent til test af de 8 remote-action-scripts

## Formål

SellYourSaaS-agenten kalder de 8 remote actions via SSH. Dette harness
simulerer agentens kald og verificerer exit-koder + side-effects, så
vi opdager protokolbrud tidligt — også når SellYourSaaS opdateres.

## Kør lokalt

```bash
# 1. Start test-cluster (k3d)
k3d cluster create saas-test
# 2. Kør harnesset
./ci/run-tests.sh
```

## Hvad harnesset tester

| Test | Forventet side-effect |
|---|---|
| deploy | namespace `tenant-test1` + helm-release + ingress + DB up + `/healthz` 200 |
| deploy (igen) | idempotent: ingen fejl, samme version |
| suspend | alle deployments/sts replicas=0, PVC bevaret, cronjobs slettet |
| unsuspend | replicas tilbage, cronjobs genskabt |
| refresh | helm upgrade --reuse-values, ingen fejl |
| recreateauthorizedkeys | ny SealedSecret `platform-access` |
| rollback efter migrering | pre-migration-snapshot gendannet + tidligere version kørende |
| undeploy | DB-dump til S3 først, helm uninstall + namespace slettet, DNS-record slettet |

## Exit-kriterium

Alle tests grønne = scripts er kompatible med SellYourSaaS-agentens
remote-action-protokol. Køres automatisk ved hver opdatering af
SellYourSaaS i dev-instansen og ved hver ændring af scripts/chart.
