# Dolibarr Tenant Helm Chart (skeleton)

Chart pr. tenant, deployes af `Scripts/deploy.sh` i namespace `tenant-{k8s_namespace}`.

Komponenter:
- Dolibarr Deployment + Service (`dolibarr:1.1` i chartet, default)
- MariaDB StatefulSet + PVC
- Ingress (Traefik) + cert-manager-annotation
- NetworkPolicy (default deny; tillad ingress-controller + DNS + egress-mail)
- ResourceQuota
- `/healthz`-endpoint i Dolibarr-deploymenten (healthcheck-endpoint — bruges af SellYourSaaS-agenten og Prometheus)

Struktur:
- `Chart.yaml`
- `values.yaml` (defaults pr. plan: quota, retention, resources)
- `templates/*.yaml`

Deployes med: `helm upgrade --install tenant $CHART -n $NS --set image.tag=... --set domain=...`
