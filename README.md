# saasplatform

Platform til håndtering af SaaS-tenants: [SellYourSaaS](https://github.com/DoliCloud/sellyoursaas) (uændret) til kunder/abonnementer/fakturering + Kubernetes-runner til containerbaserede tenants.

## Struktur

| Mappe | Indhold |
|---|---|
| [Docs/](Docs/) | [Arkitektur.md](Docs/Arkitektur.md) (rev. 6), [Fase 1a Installationstjekliste](Docs/Fase%201a%20Installationstjekliste.md) |
| [Scripts/](Scripts/) | Remote-action-scripts til K8s-runneren (`lib.sh` + deploy/suspend/unsuspend/undeploy/refresh/recreateauthorizedkeys) |
| [Helm/](Helm/) | Helm-chart pr. Dolibarr-tenant (Deployment, MariaDB, Ingress, NetworkPolicy, Quota) |
| [CI/](CI/) | Mock-agent-harness + GitHub Actions (protokol-test + k3d-integrationstest) |

## Hurtig start (dev)

```bash
k3d cluster create saas-test
./CI/run-tests.sh
```

Se [Docs/Arkitektur.md](Docs/Arkitektur.md) for beslutninger (Cloudflare, Wasabi, MariaDB 11.4, k3s, Traefik) og [Scripts/README.md](Scripts/README.md) for runner-krav.
