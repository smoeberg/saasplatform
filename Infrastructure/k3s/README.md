# k3s Produktionscluster - Opsætningsguide

## Overblik

Produktions-k3s cluster til saasplatform med:
- **k3s** (lightweight Kubernetes)
- **Traefik** (Ingress controller, inkluderet i k3s)
- **cert-manager** (TLS certifikater)
- **sealed-secrets** (Secret management)
- **Metrics-server** (Resource metrics)

## Forudsætninger

- Ubuntu 22.04 LTS server (2+ vCPUs, 4GB+ RAM, 50GB+ disk)
- sudo adgang
- Domæne med DNS-adgang (Cloudflare)
- SSH-adgang til serveren

## Installation

### 1. Server forberedelse

```bash
# Opdater system
sudo apt-get update && sudo apt-get upgrade -y

# Installer nødvendige pakker
sudo apt-get install -y \
  curl \
  wget \
  git \
  jq \
  yq \
  openssl \
  htop \
  net-tools \
  nfs-common

# Deaktiver swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Konfigurer sysctl for Kubernetes
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system
```

### 2. Installer k3s

```bash
# Installer k3s med Traefik og metrics-server
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san $(hostname -f) \
  --tls-san $(curl -s ifconfig.me) \
  --disable traefik \
  --disable servicelb \
  --kubelet-arg "eviction-hard=memory.available<500Mi,nodefs.available<1Gi" \
  --write-kubeconfig-mode 644

# Verificer installation
sudo kubectl get nodes
sudo kubectl get pods -A
```

### 3. Konfigurer kubectl adgang

```bash
# Opret .kube directory
mkdir -p ~/.kube

# Kopier kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Test adgang
kubectl get nodes
```

### 4. Installer Traefik (Ingress Controller)

```bash
# Opret namespace
kubectl create namespace traefik

# Installer Traefik via Helm
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Installer med custom values
helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  -f Infrastructure/k3s/traefik-values.yaml

# Verificer
kubectl get pods -n traefik
kubectl get svc -n traefik
```

### 5. Installer cert-manager

```bash
# Opret namespace
kubectl create namespace cert-manager

# Installer cert-manager CRDs
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml

# Installer cert-manager via Helm
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.14.4 \
  --set installCRDs=true \
  -f Infrastructure/k3s/cert-manager-values.yaml

# Verificer
kubectl get pods -n cert-manager

# Opret ClusterIssuer (Cloudflare)
kubectl apply -f Infrastructure/k3s/cloudflare-issuer.yaml
```

### 6. Installer sealed-secrets

```bash
# Installer sealed-secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.22.0/controller.yaml

# Installer kubeseal CLI
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.22.0/kubeseal-0.22.0-linux-amd64.tar.gz
tar -xvf kubeseal-0.22.0-linux-amd64.tar.gz
sudo mv kubeseal /usr/local/bin/
rm kubeseal-0.22.0-linux-amd64.tar.gz

# Generer cert for kubeseal
kubeseal --key-renew-period=24h --key-cutoff-period=168h \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml > Infrastructure/k3s/kubeseal-cert.pem

# Verificer
kubectl get pods -n kube-system | grep sealed-secrets
```

### 7. Installer metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch for k3s
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Verificer
kubectl top nodes
```

### 8. Konfigurer StorageClass

```bash
# For local storage (til test)
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

# For produktion (NFS, Longhorn, etc.) - se dokumentation
```

## k3s Runner VM (uden for clusteret)

### 1. Opret dedikeret VM

- **Specs**: 2 vCPUs, 2GB RAM, 20GB disk
- **OS**: Ubuntu 22.04 LTS
- **Netværk**: Adgang til k3s API (port 6443)

### 2. Installer nødvendige pakker

```bash
sudo apt-get update && sudo apt-get install -y \
  curl \
  wget \
  git \
  jq \
  yq \
  openssl \
  kubectl \
  helm \
  kubeseal
```

### 3. Konfigurer kubeconfig

```bash
# Kopier kubeconfig fra k3s master
scp user@k3s-master:.kube/config ~/.kube/config

# Test adgang
kubectl get nodes
```

### 4. Installer saasplatform scripts

```bash
# Klon repo
sudo mkdir -p /opt/saasplatform
sudo chown $(id -u):$(id -g) /opt/saasplatform

# Kopier scripts
cp -r Scripts /opt/saasplatform/
cp -r Helm /opt/saasplatform/

# Konfigurer miljøvariabler
cat <<EOF | sudo tee /etc/saasplatform/config
KUBECONFIG=/etc/saasplatform/kubeconfig
CHART_DIR=/opt/saasplatform/Helm
VALUES_DIR=/etc/saasplatform/values
STATUS_DIR=/var/lib/saasplatform/status
TENANT_DOMAIN=kunder.saasplatform.dk
DUMP_DIR=/var/backups/saasplatform
S3_ENDPOINT=https://s3.wasabisys.com
S3_BUCKET=saasplatform-backups
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
CLOUDFLARE_ZONE_ID=${CLOUDFLARE_ZONE_ID}
KUBESEAL_CERT=/etc/saasplatform/kubeseal-cert.pem
EOF

# Kopier kubeseal cert
cp Infrastructure/k3s/kubeseal-cert.pem /etc/saasplatform/

# Opret mapper
sudo mkdir -p /etc/saasplatform/values /var/lib/saasplatform/status /var/backups/saasplatform
sudo chown -R $(id -u):$(id -g) /etc/saasplatform /var/lib/saasplatform /var/backups/saasplatform
```

### 5. Konfigurer RBAC

```bash
# Opret service account
kubectl create serviceaccount saasplatform-runner -n default

# Opret role
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: saasplatform-runner
  namespace: default
rules:
- apiGroups: ["", "apps", "batch", "networking.k8s.io"]
  resources: ["*" ]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["bitnami.com"]
  resources: ["sealedsecrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF

# Bind role til service account
kubectl create rolebinding saasplatform-runner-binding \
  --role=saasplatform-runner \
  --serviceaccount=default:saasplatform-runner

# Opret kubeconfig for service account
kubectl get secret $(kubectl get serviceaccount saasplatform-runner -o jsonpath='{.secrets[0].name}') \
  -o jsonpath='{.data.token}' | base64 --decode > /tmp/token

cat <<EOF | sudo tee /etc/saasplatform/kubeconfig
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $(sudo cat /etc/rancher/k3s/k3s-server-ca.crt | base64 | tr -d '\n')
    server: https://$(curl -s ifconfig.me):6443
  name: saasplatform
contexts:
- context:
    cluster: saasplatform
    namespace: default
    user: saasplatform-runner
  name: saasplatform
current-context: saasplatform
users:
- name: saasplatform-runner
  user:
    token: $(cat /tmp/token | base64 | tr -d '\n')
EOF

rm /tmp/token
```

### 6. Konfigurer heartbeat

```bash
# Opret cron-job for heartbeat
cat <<EOF | sudo tee /etc/cron.d/saasplatform-heartbeat
*/5 * * * * ${USER} curl -X POST http://sellyoursaas-master/api/heartbeat -H "Authorization: Bearer ${HEARTBEAT_TOKEN}" -H "Content-Type: application/json" -d '{"runner": "k3s-prod", "timestamp": "$(date -Iseconds)"}'
EOF

# Log rotation
sudo logrotate -f /etc/logrotate.d/saasplatform 2>/dev/null || true
```

## Drift

### Opgradering af k3s

```bash
# Tjek nuværende version
kubectl get nodes -o wide

# Opgrader (se https://docs.k3s.io/upgrade)
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --kubelet-arg "eviction-hard=memory.available<500Mi,nodefs.available<1Gi"

# Verificer
kubectl get nodes
```

### Backup af k3s

```bash
# Backup af k3s data
sudo tar -czvf /backup/k3s-$(date +%Y%m%d).tar.gz /var/lib/rancher/k3s/

# Backup af etcd (hvis ekstern)
# Se: https://docs.k3s.io/datastore
```

### Monitoring

Se [Infrastructure/monitoring/README.md](../monitoring/README.md) for Prometheus + Grafana setup.

## Fejlfinding

### k3s tjener ikke

```bash
# Tjek service status
sudo systemctl status k3s

# Tjek logs
sudo journalctl -u k3s -f

# Genstart
sudo systemctl restart k3s
```

### Traefik fungerer ikke

```bash
# Tjek pods
kubectl get pods -n traefik

# Tjek logs
kubectl logs -n traefik -l app.kubernetes.io/name=traefik

# Tjek service
kubectl get svc -n traefik
```

### cert-manager fungerer ikke

```bash
# Tjek pods
kubectl get pods -n cert-manager

# Tjek logs
kubectl logs -n cert-manager -l app=cert-manager

# Tjek ClusterIssuer
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod
```

## Sikkerhed

### Firewall regler

```bash
# Tillad k3s API (6443)
sudo ufw allow 6443/tcp

# Tillad Traefik HTTP/HTTPS (80/443)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Tillad SSH
sudo ufw allow 22/tcp

# Aktiver firewall
sudo ufw enable
```

### Adgangskontrol

- **k3s API**: Kun tillad adgang fra runner VM og admin IPs
- **Traefik dashboard**: Deaktiveret i produktion
- **kubectl adgang**: Kun via service account med minimal RBAC

## Ressourcer

- [k3s Dokumentation](https://docs.k3s.io/)
- [Traefik Dokumentation](https://doc.traefik.io/traefik/)
- [cert-manager Dokumentation](https://cert-manager.io/docs/)
- [sealed-secrets Dokumentation](https://github.com/bitnami-labs/sealed-secrets)
