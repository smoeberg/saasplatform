# SellYourSaaS package-scripts til Kubernetes deployment

Disse scripts implementerer de 8 remote actions, som SellYourSaaS-agenten
kalder på deployment-serveren af typen "kubernetes"-runner. De køres
af agenten med standard-parametre fra SellYourSaaS.

Krav på runneren:
- `kubectl` + `helm` installeret
- Kubeconfig med rettigheder til at oprette namespaces, deployments,
  services, ingress, PVC'er og secrets (cluster-scoped for tildelt namespace-prefix)
- `SELLYOURSAAS_INSTANCE_NAME`, `SELLYOURSAAS_DOLIBARRINSTANCE_URL` osv.
  sættes af agenten (se SellYourSaaS docs, "setup of packages")
- Environment: `SAAS_CHART_DIR` peger på Helm-charts-repoet

Idempotens: alle scripts bruger `helm upgrade --install` og
`kubectl apply` — de kan altid køres igen.

Fail-closed: deploy afsluttes med exit != 0, hvis health-check efter
`--wait` ikke er grøn; agenten rapporterer fejlen tilbage til master.
