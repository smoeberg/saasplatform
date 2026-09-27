# Fase 1b - Installationstjekliste: K8s Grundintegration

## Formål

Implementere **Kubernetes deployment-type** for Dolibarr ERP-tenants med fuld integration til SellYourSaaS.

**Exit-kriterier:**
- 10 fulde gennemløb af K8s-flowet (deploy → suspend → unsuspend → undeploy)
- cert-manager-fornyelse under suspension verificeret
- Protokol-test (CI-niveau 1) grøn

## Overblik

Fase 1b bygger oven på fase 1a (native deployment) og tilføjer:
1. **k3s-cluster** med Traefik, cert-manager, sealed-secrets
2. **K8s-runner VM** (uden for clusteret) med kubectl/helm/kubeconfig
3. **"kubernetes"-package** til Dolibarr med Helm-chart + 8 remote-action scripts
4. **DNS-automatisering** (Cloudflare API)

## Arkitektur Reference

Se [Arkitektur.md](../Arkitektur.md) for:
- §3.2: Package-type "kubernetes" integration
- §3.3: Dataplane (Dolibarr ERP pr. tenant)
- §3.3.1: Instance↔namespace-mapping og secrets-flow
- §3.7: K8s-runner hardening og placering
- §5: Fase 1b detaljer

## Forudsætninger

- [ ] Fase 1a er færdig (native deployment fungerer)
- [ ] SellYourSaaS master-server kører (Dolibarr + modul)
- [ ] Minst én native deployment-server fungerer
- [ ] Adgang til GitHub Container Registry (GHCR)
- [ ] Cloudflare API token og zone ID tilgængelig

---

## 1. k3s Cluster Setup

### 1.1 Installer k3s

- [ ] **Server opsætning**
  - [ ] Dedikeret VM (min. 4 vCPU, 8GB RAM, 100GB disk)
  - [ ] Ubuntu 22.04 LTS installeret
  - [ ] SSH-adgang konfigureret
  - [ ] Firewall: port 6443 (Kubernetes API), 80/443 (Traefik), 22 (SSH)

- [ ] **Installer k3s**
  ```bash
  curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
  ```
  > **Note:** Traefik deaktiveres her for at installere manuelt med korrekte indstillinger

- [ ] **Verificer installation**
  ```bash
  sudo kubectl get nodes
  sudo kubectl get pods -A
  ```

### 1.2 Installer Traefik Ingress Controller

- [ ] **Installer Traefik via Helm**
  ```bash
  helm repo add traefik https://traefik.github.io/charts
  helm repo update
  helm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --create-namespace \
    --set service.type=LoadBalancer \
    --set ports.web.redirectTo=websecure \
    --set ports.websecure.tls.enabled=true
  ```

- [ ] **Hent LoadBalancer IP**
  ```bash
  kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
  ```
  > **Gem denne IP** til Cloudflare DNS opsætning

### 1.3 Installer cert-manager

- [ ] **Installer CRDs**
  ```bash
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
  ```

- [ ] **Installer cert-manager via Helm**
  ```bash
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version v1.14.4 \
    --set installCRDs=true
  ```

- [ ] **Opret ClusterIssuer (Let's Encrypt)**
  ```yaml
  # Gem som Infrastructure/k3s/cert-manager-issuer.yaml
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: letsencrypt-prod
  spec:
    acme:
      email: admin@saasplatform.dev
      server: https://acme-v02.api.letsencrypt.org/directory
      privateKeySecretRef:
        name: letsencrypt-prod
      solvers:
        - http01:
            ingress:
              class: traefik
  ```
  ```bash
  kubectl apply -f Infrastructure/k3s/cert-manager-issuer.yaml
  ```

### 1.4 Installer SealedSecrets

- [ ] **Installer controller**
  ```bash
  kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.22.0/controller.yaml
  ```

- [ ] **Installer kubeseal CLI** (på K8s-runner VM)
  ```bash
  wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.22.0/kubeseal-0.22.0-linux-amd64.tar.gz
  tar -xvf kubeseal-0.22.0-linux-amd64.tar.gz
  sudo mv kubeseal /usr/local/bin/
  rm kubeseal-0.22.0-linux-amd64.tar.gz
  ```

- [ ] **Hent SealedSecrets certifikat**
  ```bash
  kubeseal --cert Infrastructure/k3s/sealed-secrets-cert.pem \
    --controller-name=sealed-secrets \
    --controller-namespace=kube-system
  ```

### 1.5 Installer Velero (Backup)

- [ ] **Installer Velero CLI**
  ```bash
  wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
  tar -xvf velero-v1.12.0-linux-amd64.tar.gz
  sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/
  rm -rf velero-v1.12.0-linux-amd64 velero-v1.12.0-linux-amd64.tar.gz
  ```

- [ ] **Installer Velero i clusteret** (konfigureres i fase 1c)
  ```bash
  velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.4.0 \
    --bucket saasplatform-backups \
    --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000 \
    --snapshot-location-config region=us-east-1 \
    --secret-file ./Infrastructure/velero/velero-credentials \
    --namespace velero
  ```

---

## 2. K8s-Runner VM Setup

### 2.1 VM Opsætning

- [ ] **Dedikeret VM** (min. 2 vCPU, 4GB RAM, 50GB disk)
- [ ] Ubuntu 22.04 LTS
- [ ] SSH-adgang fra SellYourSaaS master

### 2.2 Installer Afhængigheder

- [ ] **Installer kubectl**
  ```bash
  sudo apt-get update
  sudo apt-get install -y curl
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  ```

- [ ] **Installer Helm**
  ```bash
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ```

- [ ] **Installer yq**
  ```bash
  wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  chmod +x /usr/local/bin/yq
  ```

- [ ] **Installer jq**
  ```bash
  sudo apt-get install -y jq
  ```

### 2.3 Konfigurer kubeconfig

- [ ] **Kopier kubeconfig fra k3s server**
  ```bash
  sudo mkdir -p /etc/saasplatform
  sudo cp /etc/rancher/k3s/k3s.yaml /etc/saasplatform/kubeconfig
  sudo chmod 644 /etc/saasplatform/kubeconfig
  ```

- [ ] **Test adgang**
  ```bash
  export KUBECONFIG=/etc/saasplatform/kubeconfig
  kubectl get nodes
  ```

### 2.4 Opret mapper og miljø

- [ ] **Opret directory struktur**
  ```bash
  sudo mkdir -p /opt/saasplatform/Helm/erp-tenant
  sudo mkdir -p /etc/saasplatform/values
  sudo mkdir -p /var/lib/saasplatform/status
  sudo mkdir -p /var/backups/saasplatform/pre-undeploy
  sudo mkdir -p /var/log/saasplatform
  ```

- [ ] **Kopier Helm chart og scripts**
  ```bash
  sudo cp -r /path/to/saasplatform/Helm/erp-tenant/* /opt/saasplatform/Helm/erp-tenant/
  sudo cp -r /path/to/saasplatform/Scripts/* /opt/saasplatform/scripts/
  sudo chmod +x /opt/saasplatform/scripts/*.sh
  sudo chown -R saasplatform:saasplatform /opt/saasplatform /etc/saasplatform /var/lib/saasplatform /var/backups/saasplatform /var/log/saasplatform
  ```

- [ ] **Opret systemd service for scripts**
  ```ini
  # /etc/systemd/system/saasplatform-k8s.service
  [Unit]
  Description=saasplatform K8s Runner
  After=network.target

  [Service]
  Type=simple
  User=saasplatform
  WorkingDirectory=/opt/saasplatform
  Environment=KUBECONFIG=/etc/saasplatform/kubeconfig
  Environment=CHART_DIR=/opt/saasplatform/Helm/erp-tenant
  Environment=VALUES_DIR=/etc/saasplatform/values
  Environment=STATUS_DIR=/var/lib/saasplatform/status
  Environment=TENANT_DOMAIN=kunder.saasplatform.dev
  Environment=S3_ENDPOINT=https://s3.wasabisys.com
  Environment=S3_BUCKET=saasplatform-backups
  Environment=CLOUDFLARE_API_TOKEN=YOUR_TOKEN
  Environment=CLOUDFLARE_ZONE_ID=YOUR_ZONE_ID
  ExecStart=/bin/bash -c "while true; do sleep 3600; done"
  Restart=always

  [Install]
  WantedBy=multi-user.target
  ```
  ```bash
  sudo systemctl daemon-reload
  sudo systemctl enable saasplatform-k8s
  sudo systemctl start saasplatform-k8s
  ```

### 2.5 Konfigurer RBAC

- [ ] **Opret ServiceAccount og Role**
  ```yaml
  # Infrastructure/k3s/saasplatform-rbac.yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: saasplatform-runner
    namespace: default
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: saasplatform-tenant-admin
    namespace: default
  rules:
    - apiGroups: [""]
      resources: ["namespaces"]
      verbs: ["get", "list", "create", "delete"]
    - apiGroups: [""]
      resources: ["secrets", "configmaps", "persistentvolumeclaims"]
      verbs: ["get", "list", "create", "update", "delete"]
    - apiGroups: ["apps"]
      resources: ["deployments", "statefulsets", "replicasets"]
      verbs: ["get", "list", "create", "update", "delete"]
    - apiGroups: ["batch"]
      resources: ["cronjobs", "jobs"]
      verbs: ["get", "list", "create", "update", "delete"]
    - apiGroups: ["networking.k8s.io"]
      resources: ["ingresses", "networkpolicies"]
      verbs: ["get", "list", "create", "update", "delete"]
    - apiGroups: [""]
      resources: ["resourcequotas"]
      verbs: ["get", "list", "create", "update", "delete"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: saasplatform-tenant-admin-binding
    namespace: default
  subjects:
    - kind: ServiceAccount
      name: saasplatform-runner
      namespace: default
  roleRef:
    kind: Role
    name: saasplatform-tenant-admin
    apiGroup: rbac.authorization.k8s.io
  ```
  ```bash
  kubectl apply -f Infrastructure/k3s/saasplatform-rbac.yaml
  ```

- [ ] **Opret kubeconfig med begrænset adgang**
  ```bash
  # Hent service account token
  kubectl create serviceaccount saasplatform-runner
  SECRET=$(kubectl get serviceaccount saasplatform-runner -o jsonpath='{.secrets[0].name}')
  TOKEN=$(kubectl get secret $SECRET -o jsonpath='{.data.token}' | base64 --decode)
  
  # Opret kubeconfig
  kubectl config set-credentials saasplatform-runner --token=$TOKEN
  kubectl config set-context saasplatform-runner --cluster=k3s --user=saasplatform-runner
  kubectl config use-context saasplatform-runner
  kubectl config view --minify > /etc/saasplatform/kubeconfig
  ```

---

## 3. Dolibarr Kubernetes Package

### 3.1 Opret Package i SellYourSaaS

- [ ] **Package definition** (via SellYourSaaS admin)
  - **Name:** `dolibarr-k8s`
  - **Type:** `kubernetes`
  - **Version:** `1.0.0`
  - **Description:** Dolibarr ERP med Kubernetes deployment

- [ ] **Sources**
  - **Git URL:** `https://github.com/smoeberg/saasplatform`
  - **Branch:** `main`
  - **Path:** `Helm/erp-tenant`

### 3.2 Konfigurer Remote Actions

| Action | Script | Beskrivelse |
|--------|--------|-------------|
| beforedeploy | `/opt/saasplatform/scripts/beforedeploy.sh` | Pre-flight checks |
| afterdeploy | `/opt/saasplatform/scripts/afterdeploy.sh` | Helm install + healthz check |
| beforeundeploy | `/opt/saasplatform/scripts/beforeundeploy.sh` | DB backup før sletning |
| afterundeploy | `/opt/saasplatform/scripts/afterundeploy.sh` | Helm uninstall + namespace delete |
| aftersuspend | `/opt/saasplatform/scripts/aftersuspend.sh` | Helm upgrade --set suspended=true |
| beforeunsuspend | (Ikke brugt) | - |
| afterunsuspend | `/opt/saasplatform/scripts/afterunsuspend.sh` | Helm upgrade --set suspended=false |
| refresh | `/opt/saasplatform/scripts/refresh.sh` | Re-apply ønsket tilstand |
| recreateauthorizedkeys | `/opt/saasplatform/scripts/recreateauthorizedkeys.sh` | SSH key rotation |
| cron | `/opt/saasplatform/scripts/cron.sh` | Healthz check af alle tenants |

### 3.3 Package Configuration Templates

- [ ] **config-templates** (SellYourSaaS package definition)
  ```yaml
  # Package: dolibarr-k8s
  # Service: Dolibarr ERP (K8s)
  
  # Template for values.yaml
  template: |
    instance: "{{contract_id}}"
    domain: "{{contract_id}}.kunder.saasplatform.dev"
    suspended: false
    image:
      repository: ghcr.io/smoeberg/dolibarr
      tag: "{{package_version}}"
    dolibarr:
      resources:
        requests:
          cpu: {{plan_cpu_requests}}
          memory: {{plan_memory_requests}}
        limits:
          cpu: {{plan_cpu_limits}}
          memory: {{plan_memory_limits}}
    db:
      enabled: true
      storage: {{plan_storage}}
    quota:
      requestsCpu: "{{plan_cpu_requests}}"
      requestsMemory: {{plan_memory_requests}}
      limitsCpu: "{{plan_cpu_limits}}"
      limitsMemory: {{plan_memory_limits}}
      pvc: "{{plan_pvc_count}}"
    networkPolicy:
      defaultDeny: true
      egressMail: {{plan_egress_mail}}
  
  # Renderes til: /etc/saasplatform/values/tenant-{contract_id}.yaml
  render_path: /etc/saasplatform/values/tenant-{{contract_id}}.yaml
  ```

---

## 4. DNS Automatisering (Cloudflare)

### 4.1 Konfigurer Cloudflare

- [ ] **Cloudflare API Token**
  - Opret token med `Zone:DNS:Edit` tilladelse
  - Gem som secret på K8s-runner VM

- [ ] **Zone ID**
  - Find zone ID for dit domæne
  - Gem som miljøvariabel

### 4.2 Test DNS Opsætning

- [ ] **Test DNS oprettelse**
  ```bash
  export CLOUDFLARE_API_TOKEN="your_token"
  export CLOUDFLARE_ZONE_ID="your_zone_id"
  export CLOUDFLARE_INGRESS_IP="$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  
  # Test med deploy.sh
  ./Scripts/deploy.sh test-tenant-1
  ```

- [ ] **Verificer DNS record**
  ```bash
  dig test-tenant-1.kunder.saasplatform.dev
  ```

---

## 5. Test Scenarier

### 5.1 Normal Flow Test

```
1. Kunde registrerer sig via myaccount
2. SellYourSaaS opretter kontrakt
3. SellYourSaaS kalder beforedeploy
4. beforedeploy validerer systemet
5. SellYourSaaS kalder deploy
6. deploy opretter namespace, Helm release, DB, Ingress
7. DNS record oprettes via Cloudflare API
8. SellYourSaaS kalder afterdeploy
9. afterdeploy venter på healthz
10. Tenant er klar til brug
11. Faktura genereres
12. Betaling gennemføres
13. Kontrakt aktiveres
```

**Test kommando:**
```bash
# Simuler flow manuelt
export SELLYOURSAAS_INSTANCE_NAME="test-1"
export SELLYOURSAAS_DOLIBARRINSTANCE_URL="https://test-1.kunder.saasplatform.dev"
export SELLYOURSAAS_VERSION="23.0.1"

./Scripts/deploy.sh test-1
```

### 5.2 Suspension Test

```
1. Tenant er aktiv
2. Betaling udløber
3. SellYourSaaS sender dunning e-mail
4. Betaling ikke modtaget
5. SellYourSaaS kalder suspend
6. suspend sletter CronJobs, skalerer workloads til 0
7. Ingress peger på suspended-page
8. cert-manager fornyelse fungerer (testes eksplicit)
```

**Test kommando:**
```bash
./Scripts/suspend.sh test-1

# Verificer suspension
kubectl get pods -n tenant-test-1
kubectl get cronjob -n tenant-test-1
kubectl get ingress -n tenant-test-1 -o yaml | grep suspended

# Test cert-manager fornyelse under suspension
kubectl describe certificate -n tenant-test-1
```

### 5.3 Unsuspension Test

```
1. Tenant er suspended
2. Kunde betaler
3. SellYourSaaS modtager betaling
4. SellYourSaaS kalder unsuspend
5. unsuspend genskaber CronJobs, skalerer workloads til 1
6. Ingress peger tilbage på Dolibarr
7. Healthz check OK
```

**Test kommando:**
```bash
./Scripts/unsuspend.sh test-1

# Verificer unsuspension
kubectl get pods -n tenant-test-1
kubectl get cronjob -n tenant-test-1
```

### 5.4 Undeploy Test

```
1. Tenant opsiges
2. SellYourSaaS kalder beforeundeploy
3. beforeundeploy tager DB backup
4. SellYourSaaS kalder undeploy
5. undeploy sletter Helm release og namespace
6. DNS record slettes
```

**Test kommando:**
```bash
./Scripts/undeploy.sh test-1

# Verificer undeploy
kubectl get namespace tenant-test-1 --ignore-not-found
ls /etc/saasplatform/values/tenant-test-1.yaml
```

---

## 6. Fejl-Injektion Tests

### 6.1 Deploy Fejler (Ugyldige values)

```bash
# Opret ugyldige values
cat > /etc/saasplatform/values/tenant-test-fail.yaml << 'EOF'
instance: "test-fail"
# Mangler domain
suspended: false
EOF

./Scripts/deploy.sh test-fail || echo "✅ Fejl håndteret korrekt"
```

### 6.2 Suspend Fejler (Release Findes Ikke)

```bash
./Scripts/suspend.sh non-existent-tenant || echo "✅ Fejl håndteret korrekt"
```

### 6.3 Healthz Timeout Test

```bash
# Simuler healthz timeout
export HEALTHZ_TIMEOUT=5
./Scripts/deploy.sh test-timeout || echo "✅ Timeout håndteret korrekt"
```

---

## 7. cert-manager Fornyelse Test

### 7.1 Test Fornyelse Under Suspension

**Ifølge arkitektur §3.3:** cert-manager's HTTP-01-solver skal fortsat virke under suspension.

```bash
# Deploy tenant
./Scripts/deploy.sh cert-test-1

# Vent på certifikat
sleep 30
kubectl get certificate -n tenant-cert-test-1

# Suspender tenant
./Scripts/suspend.sh cert-test-1

# Vent 1 minut (cert-manager check interval)
sleep 60

# Tjek certifikat status
kubectl describe certificate -n tenant-cert-test-1

# Forventet: Certificate status = True
CERT_STATUS=$(kubectl get certificate -n tenant-cert-test-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[[ "$CERT_STATUS" == "True" ]] && echo "✅ cert-manager fornyelse under suspension virker"
```

---

## 8. Exit Kriterier

### Minimum (for at gå videre til fase 1c)

- [ ] 10 fulde gennemløb af normal flow (deploy → suspend → unsuspend → undeploy)
- [ ] 5 suspension tests
- [ ] 5 unsuspension tests
- [ ] 5 undeploy tests
- [ ] cert-manager fornyelse under suspension verificeret
- [ ] Protokol-test (CI-niveau 1) grøn

### Fuldt (anbefalet)

- [ ] Alle 10+ tests pr. scenarium bestået
- [ ] Fejl-injektion tests bestået
- [ ] Alle exit-kriterier dokumenteret
- [ ] Runbook for fejlfinding oprettet

---

## 9. Checkliste (Tjek af)

- [ ] k3s cluster kører med Traefik
- [ ] cert-manager installeret og fungerende
- [ ] SealedSecrets controller installeret
- [ ] Velero installeret (fase 1c)
- [ ] K8s-runner VM opsat med alle afhængigheder
- [ ] RBAC konfigureret for saasplatform-runner
- [ ] kubeconfig konfigureret med begrænset adgang
- [ ] Helm chart (erp-tenant) kopieret til /opt/saasplatform/Helm/erp-tenant
- [ ] Scripts kopieret til /opt/saasplatform/scripts
- [ ] Directory struktur oprettet (/etc/saasplatform, /var/lib/saasplatform, etc.)
- [ ] Package oprettet i SellYourSaaS (dolibarr-k8s)
- [ ] Remote actions konfigureret
- [ ] Config templates oprettet
- [ ] Cloudflare API token og zone ID konfigureret
- [ ] DNS test succesfuld
- [ ] 10 normal flow tests bestået
- [ ] 5 suspension tests bestået
- [ ] 5 unsuspension tests bestået
- [ ] 5 undeploy tests bestået
- [ ] cert-manager fornyelse under suspension verificeret
- [ ] Fejl-injektion tests bestået
- [ ] CI-niveau 1 test grøn

---

## 10. Ressourcer

- [Arkitektur Dokumentation](../Arkitektur.md)
- [Helm Chart: erp-tenant](../../Helm/erp-tenant/README.md)
- [Scripts Dokumentation](../../Scripts/README.md)
- [SellYourSaaS Dokumentation](https://github.com/DoliCloud/sellyoursaas)
- [Cloudflare API Dokumentation](https://api.cloudflare.com/)
- [k3s Dokumentation](https://docs.k3s.io/)
- [Helm Dokumentation](https://helm.sh/docs/)

---

## 11. Fejlfinding

### k3s Fejl

```bash
# Tjek k3s service
sudo systemctl status k3s

# Tjek logs
sudo journalctl -u k3s -f

# Genstart k3s
sudo systemctl restart k3s
```

### Traefik Fejl

```bash
# Tjek Traefik pods
kubectl get pods -n traefik

# Tjek Traefik logs
kubectl logs -n traefik -l app.kubernetes.io/name=traefik

# Tjek Traefik service
kubectl get svc -n traefik
```

### cert-manager Fejl

```bash
# Tjek cert-manager pods
kubectl get pods -n cert-manager

# Tjek cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Tjek certificate status
kubectl describe certificate -n tenant-{instance}
```

### SealedSecrets Fejl

```bash
# Tjek SealedSecrets controller
kubectl get pods -n kube-system -l name=sealed-secrets-controller

# Tjek SealedSecrets logs
kubectl logs -n kube-system -l name=sealed-secrets-controller
```

### Script Fejl

```bash
# Tjek script logs
sudo tail -f /var/log/syslog | grep saasplatform

# Kør script manuelt med debug
bash -x ./Scripts/deploy.sh test-1
```

### DNS Fejl

```bash
# Tjek DNS records
curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" | jq

# Test DNS propagation
dig test-1.kunder.saasplatform.dev
```
