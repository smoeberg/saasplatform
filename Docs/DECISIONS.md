# Beslutningslog (DECISIONS)

Én linje pr. beslutning: dato — beslutning — begrundelse — afvist alternativ. Kilde: arkitekturdokumentet og chat-gennemgangen (sep. 2026).

| Dato | Beslutning | Begrundelse | Afvist alternativ |
|---|---|---|---|
| 2026-09-25 | SellYourSaaS bruges uændret; ingen patches/forks | Frit opdaterbart; kernen er kompleks driftssikret kode | Selvbygget CRM/billing (for omfattende) |
| 2026-09-25 | Dolibarr = source of truth for kunder/kontrakter/abonnementer | SellYourSaaS leverer fakturering, suspension, dunning, kundecenter | Egen management-API og DB (for omfattende, rev. 2-ideen) |
| 2026-09-25 | Kubernetes-operator/CRD **udskudt** | Scripts er enkle og forbinder ikke Dolibarr med clusteret; CRD først ved vækst | Argo/Flux-operator fra dag ét (over-engineering) |
| 2026-09-25 | To deployment-typer fra dag ét: native + Kubernetes | PIM (uden persondata) kan køre billig native; Dolibarr (persondata) kræver container-isolation | Kun K8s (dyrt pr. tenant), kun native (utilstrækkelig isolation for ERP) |
| 2026-09-25 | Package-scripts kalder kubectl/helm fra K8s-runner (VM uden for clusteret) | SellYourSaaS' package-model er allerede plugin-punktet; ingen kernearkitektur-ændring | Operator (udskudt), webhook-API (for omfattende) |
| 2026-09-25 | Fælles lib.sh: mapping via extrafields, fail-closed | Gen-deploy skal være deterministisk; ingen klartekst-secrets | Hårdkodet NS pr. script (inkonsistent) |
| 2026-09-25 | SealedSecrets; klartekst slettes straks | GitOps-kompatibelt, ingen hemmeligheder i etcd-udtræk | EKS Secrets Manager (dyrere) |
| 2026-09-25 | DNS: Cloudflare API | Billigt, API-drevet, hurtig propagation | Route53 (bindes til AWS) |
| 2026-09-25 | S3: Wasabi | Lav pris, ingen egress-gebyrer | MinIO on-prem (ekstra drift) |
| 2026-09-25 | MariaDB 11.4 LTS | Dolibarr-kompatibel, LTS til 2029 | PostgreSQL (CloudNativePG skudt til fase 3) |
| 2026-09-25 | k3s + Traefik (k3s-standard) | Minimal, en enkelt binær; Traefik følger med | EKS/GKE (for dyrt), Nginx (ekstra installation) |
| 2026-09-25 | Canary + pre-migration-snapshot | DB-migreringer er risikable; gendanbarhed > automatiseret migration-down | Argo Rollouts (kan kun image-rollback, ikke DB) |
| 2026-09-25 | GPL-krav: egne scripts/charts i eget repo, ingen GPL-kode | Server-side-brug udløser ingen udleveringspligt; distribution til kunder gør | Distribueret on-prem-modul (under GPL — accepteret hvis relevant) |
| 2026-09-25 | Repo'et er **internt**, ikke et open source-produkt | Navnet "saasplatform" er projektnavnet; README gør det eksplicit | Omdøbning til produktnavn (vurderes ved lancement) |

*Rev. 1–6 er i Git-historikken (tag `v0.6-arkitektur`); beslutningsloggen er den gældende "hvorfor"-oversigt.*
