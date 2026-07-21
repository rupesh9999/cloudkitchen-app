# ☁️ CloudKitchen — GCP Execution Plan

> **Cloud**: GCP (us-central1) · **Orchestration**: GKE · **Registry**: Artifact Registry
> **Goal**: Spin up infrastructure layer-by-layer, integrate each layer sequentially, and deliver services live to end users.

---

## 📐 Layer Dependency Diagram

```
Layer 10 ──── DNS & Go-Live ◄──────────────────────────────────────────┐
Layer  9 ──── TLS / HTTPS (cert-manager + Let's Encrypt)              │
Layer  8 ──── Observability (Prometheus + Grafana + Loki + Promtail)   │
Layer  7 ──── Security Hardening (PSS, NetworkPolicies, Secrets)       │
Layer  6 ──── Application Services (Helm umbrella chart via ArgoCD)    │
Layer  5 ──── GitOps Engine (ArgoCD App-of-Apps)                       │
Layer  4 ──── Ingress Controller (Traefik + LoadBalancer)              │
Layer  3 ──── CI/CD Pipeline (GitHub Actions → Artifact Registry)      │
Layer  2 ──── Cluster Access & Bastion Setup                           │
Layer  1 ──── Cloud Infrastructure (Terraform: VPC, GKE, AR, IAM)      │
             ▲ FOUNDATION ─────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Minimum Version | Verify Command |
|------|----------------|----------------|
| gcloud CLI | latest | `gcloud --version` |
| Terraform | ≥ 1.5 | `terraform -version` |
| kubectl | ≥ 1.28 | `kubectl version --client` |
| Helm | v3.x | `helm version` |
| Docker | ≥ 24.x | `docker --version` |
| Git | ≥ 2.x | `git --version` |

```bash
# Authenticate to GCP
gcloud auth login
gcloud auth application-default login
gcloud config set project <YOUR_PROJECT_ID>
```

---

## Layer 1 — Cloud Infrastructure (Terraform)

**What it provisions**: VPC with GKE subnet (primary + secondary ranges for pods/services), Cloud Router + Cloud NAT, firewall rules (IAP SSH, internal, health checks), GKE cluster with private nodes + Workload Identity, Artifact Registry (single Docker repo), bastion Compute Engine VM (IAP-only access).

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `gcp-terraform/provider.tf` | Terraform + Google providers, GCS backend for remote state |
| `gcp-terraform/variables.tf` | All variable declarations |
| `gcp-terraform/terraform.tfvars` | Actual values (project ID, region, node sizes, CIDRs) |
| `gcp-terraform/main.tf` | Root module wiring 5 child modules |
| `gcp-terraform/outputs.tf` | Cluster endpoint, AR URLs, kubeconfig cmd, bastion SSH |
| `gcp-terraform/modules/vpc/` | VPC, GKE subnet with secondary ranges, Cloud Router, Cloud NAT |
| `gcp-terraform/modules/firewall/` | IAP SSH, internal traffic, GCP health check rules |
| `gcp-terraform/modules/gke/` | GKE cluster (private) + node pool + Workload Identity |
| `gcp-terraform/modules/artifact-registry/` | Single Docker repo "cloudkitchen-registry" |
| `gcp-terraform/modules/bastion/` | Compute Engine VM, no public IP, IAP-only |

**Infrastructure topology**:
```
VPC: cloudkitchen-dev  (us-central1)
├── Subnet: 10.10.0.0/20 (node IPs)
│   ├── Secondary range: 10.20.0.0/16 (pod IPs)
│   └── Secondary range: 10.30.0.0/20 (service IPs)
├── Cloud Router + Cloud NAT (egress for private nodes)
└── Firewall Rules (IAP SSH, internal, health checks)

GKE Cluster: cloudkitchen-dev (K8s 1.30, REGULAR channel)
├── Private nodes (no public IPs)
├── 2x e2-medium nodes per zone (autoscale 2→3)
├── Workload Identity enabled (built-in)
├── Master CIDR: 172.16.0.0/28
└── GCE PD CSI driver (built-in, for PVCs)

Artifact Registry: cloudkitchen-registry (DOCKER format)
└── 9 images: auth-service, user-service, restaurant-service,
    menu-service, order-service, payment-service, delivery-service,
    notification-service, frontend

Bastion: e2-small VM (IAP-tunnel only, no public IP)
```

### 1.1 Enable Required GCP APIs

```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iap.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicenetworking.googleapis.com \
  --project=<YOUR_PROJECT_ID>
```

### 1.2 Review & Customize Variables

```bash
cd gcp-terraform

# Edit terraform.tfvars — MUST set:
#   project_id = "<your-gcp-project-id>"
#   iap_allowed_users = ["user:you@gmail.com"]
cat terraform.tfvars
```

> **IMPORTANT**: Before production — tighten `master_authorized_cidrs` to your office IP. Switch to regional cluster for HA.

### 1.3 Initialize & Apply Terraform

```bash
terraform init
terraform plan          # review resources to be created
terraform apply -auto-approve
```

> ⏱️ **ETA**: ~6–10 minutes (GKE is faster than EKS)

### 1.4 Capture Outputs

```bash
terraform output cluster_name
terraform output artifact_registry_urls
terraform output kubeconfig_command
terraform output bastion_ssh_command
terraform output vpc_name
```

### ✅ Layer 1 Validation

```bash
gcloud container clusters describe cloudkitchen-dev \
  --zone us-central1-a --format='value(status)'
# Expected: RUNNING

gcloud artifacts repositories list --location=us-central1
# Expected: cloudkitchen-registry
```

---

## Layer 2 — Cluster Access & Bastion Setup

**What it does**: Configures local `kubectl` to talk to GKE, optionally sets up the bastion as a second control point via IAP tunnel.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `scripts/kubeconfig.sh` | Helper script (AWS-focused, but pattern is the same) |

### 2.1 Update Local Kubeconfig

```bash
# Use the exact command from Terraform output
gcloud container clusters get-credentials cloudkitchen-dev \
  --zone us-central1-a \
  --project <YOUR_PROJECT_ID>

# Or use the Terraform output directly
eval "$(terraform output -raw kubeconfig_command)"
```

### 2.2 Verify Cluster Connectivity

```bash
kubectl get nodes -o wide
# Expected: 2 nodes in Ready state (e2-medium)

kubectl get ns
# Expected: default, kube-system, kube-public, kube-node-lease, gke-managed-system
```

### 2.3 Bastion Access via IAP (Optional)

```bash
# Use the Terraform output command
eval "$(terraform output -raw bastion_ssh_command)"

# Or manually:
gcloud compute ssh cloudkitchen-dev-bastion \
  --zone us-central1-a \
  --tunnel-through-iap \
  --project <YOUR_PROJECT_ID>

# Inside bastion — install tools:
sudo apt-get update
sudo apt-get install -y curl gnupg lsb-release ca-certificates apt-transport-https

# kubectl via gcloud
gcloud components install kubectl

# Helm v3
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### ✅ Layer 2 Validation

```bash
kubectl cluster-info
# Expected: Kubernetes control plane is running at https://<private-endpoint>

kubectl get nodes
# Expected: 2 nodes, all Ready
```

---

## Layer 3 — CI/CD Pipeline (GitHub Actions → Artifact Registry)

**What it does**: Configures GitHub Actions to build all 9 service Docker images in parallel, scan them with Trivy, push to GCP Artifact Registry, and commit updated image tags back to the Helm values file.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `.github/workflows/ci-gcp.yaml` | GCP/AR CI pipeline (matrix build + GitOps update) |
| `scripts/build-images.sh` | Local image build helper script |
| `helm/cloudkitchen/values.yaml` | Image tags updated by CI's `update-gitops` job |
| Each service's `Dockerfile` | Per-service build definitions |

**CI pipeline flow**:
```
git push to main
    └── build (9x parallel matrix)
         ├── docker build (buildx, cached)
         ├── Trivy scan (HIGH/CRITICAL)
         └── docker push → Artifact Registry (sha + latest tags)
    └── update-gitops (runs after all builds pass)
         ├── yq patches values.yaml with new image:tag strings
         └── git commit + push "[skip ci]"
```

**Trigger paths** (auto-runs on push to main affecting):
```
auth-service/**  user-service/**  restaurant-service/**  menu-service/**
order-service/**  payment-service/**  delivery-service/**  notification-service/**
frontend/**  helm/cloudkitchen/**  .github/workflows/ci-gcp.yaml
```

### 3.1 Push Code to GitHub

```bash
git init
git add .
git commit -m "initial import"
git branch -M main
git remote add origin https://github.com/<your-username>/cloudkitchen-app.git
git push -u origin main
```

### 3.2 Create GCP Service Account for CI

```bash
PROJECT=<YOUR_PROJECT_ID>
SA=cloudkitchen-ci

# Create service account
gcloud iam service-accounts create ${SA} \
  --display-name="CloudKitchen GitHub Actions" \
  --project=${PROJECT}

# Bind Artifact Registry writer role
gcloud projects add-iam-policy-binding ${PROJECT} \
  --member="serviceAccount:${SA}@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

# Generate JSON key
gcloud iam service-accounts keys create gcp-ci-sa.json \
  --iam-account=${SA}@${PROJECT}.iam.gserviceaccount.com

# Copy the contents, then securely delete the key file
cat gcp-ci-sa.json
shred -u gcp-ci-sa.json
```

### 3.3 Configure GitHub Secrets & Variables

Navigate to **GitHub → Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|------|------|-------|
| **Secret** | `GCP_SA_KEY` | Complete JSON key contents |
| **Secret** | `GITOPS_TOKEN` | *(optional)* PAT with `contents:write` |
| **Variable** | `GCP_PROJECT_ID` | Your GCP project ID |
| **Variable** | `GCP_REGION` | `us-central1` |
| **Variable** | `AR_REPO` | `cloudkitchen-registry` |

### 3.4 Trigger the Pipeline

```bash
git commit --allow-empty -m "ci: trigger first GCP build"
git push
```

### ✅ Layer 3 Validation

```bash
# Check GitHub Actions tab — all 9 build jobs should pass

# Check Artifact Registry has images:
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/<PROJECT_ID>/cloudkitchen-registry \
  --include-tags
# Expected: 9 images with sha tags

# Verify values.yaml was auto-updated:
grep "image:" helm/cloudkitchen/values.yaml | head -5
# Expected: AR URLs with short SHA tags
```

---

## Layer 4 — Ingress Controller (Traefik)

**What it does**: Deploys Traefik as the single ingress entrypoint, provisioning a GCP Regional TCP Load Balancer with a static external IP to route traffic into the cluster.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/apps/app-traefik.yaml` | ArgoCD Application for Traefik (used in Layer 5) |
| `helm/cloudkitchen/templates/ingressroute.yaml` | Per-service path routing rules |

### 4.1 Install Traefik via Helm

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set service.type=LoadBalancer \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true \
  --set ingressRoute.dashboard.enabled=true \
  --set deployment.replicas=2 \
  --set 'ports.web.expose.default=true' \
  --set 'ports.web.exposedPort=80' \
  --set 'ports.websecure.expose.default=true' \
  --set 'ports.websecure.exposedPort=443' \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=256Mi \
  --wait --timeout=5m
```

### 4.2 Capture the External IP

```bash
# Wait for LB provisioning
kubectl -n traefik get svc traefik -w

# Capture IP (GCP gives a static IP, not a hostname)
LB_IP=$(kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Traefik LB IP: $LB_IP"
```

> **KEY DIFFERENCE FROM AWS**: GCP assigns a static **IP address**, not a hostname. DNS uses an **A record** instead of a CNAME.

### ✅ Layer 4 Validation

```bash
kubectl -n traefik get pods
# Expected: 2 traefik pods Running

curl -s -o /dev/null -w "%{http_code}" http://$LB_IP
# Expected: 404 (no routes configured yet — that's correct)
```

---

## Layer 5 — GitOps Engine (ArgoCD)

**What it does**: Installs ArgoCD, exposes it via Traefik at `/argocd`, creates the AppProject, and bootstraps the App-of-Apps pattern.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/project.yaml` | AppProject with allowed repos, namespaces, resource whitelist |
| `argocd/root-app.yaml` | Root Application (App-of-Apps) that fans out to child apps |
| `argocd/apps/app-cloudkitchen.yaml` | Child app: microservices (Helm chart) |
| `argocd/apps/app-traefik.yaml` | Child app: Traefik ingress |
| `argocd/apps/app-cert-manager.yaml` | Child app: cert-manager |
| `argocd/apps/app-monitoring.yaml` | Child app: kube-prometheus-stack (GKE-tuned: etcd/scheduler/proxy disabled) |
| `argocd/apps/app-logging.yaml` | Child app: Loki + Promtail |

### 5.1 Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argo

cat <<EOF > /tmp/argocd-values.yaml
global:
  domain: argocd.example.com
configs:
  params:
    server.insecure: true
    server.rootpath: /argocd
server:
  extraArgs:
    - --basehref
    - /argocd
    - --rootpath
    - /argocd
EOF

helm install argocd argo/argo-cd -n argo -f /tmp/argocd-values.yaml
```

### 5.2 Expose ArgoCD via Traefik

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argo
spec:
  entryPoints:
    - web
  routes:
    - match: PathPrefix(`/argocd`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
EOF
```

### 5.3 Get Admin Password

```bash
kubectl -n argo get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### 5.4 Update Repo URLs & Deploy App-of-Apps

```bash
# 1. Edit argocd/root-app.yaml and argocd/apps/app-cloudkitchen.yaml
#    Replace repoURL with your actual GitHub repository URL

# 2. Also update argocd/project.yaml sourceRepos

# 3. Apply the project and root app
kubectl apply -f argocd/project.yaml
kubectl apply -n argo -f argocd/root-app.yaml
```

> **GKE-SPECIFIC NOTE**: The `app-monitoring.yaml` already has GKE-specific tuning — it disables scraping for `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy`, and `coreDns` since GKE manages these components internally and they aren't scrapeable.

### ✅ Layer 5 Validation

```bash
echo "http://$LB_IP/argocd"
# Login: admin / <password from 5.3>

kubectl -n argo get applications
# Expected: cloudkitchen-root (fans out into child apps)
```

---

## Layer 6 — Application Services (Helm Umbrella Chart)

**What it does**: Deploys all 8 Go microservices + React frontend + in-cluster PostgreSQL + Redis + NATS via the umbrella Helm chart. ArgoCD syncs this automatically.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `helm/cloudkitchen/Chart.yaml` | Chart metadata (v0.2.0) |
| `helm/cloudkitchen/values.yaml` | All service configs, images, ports, DB, ingress |
| `helm/cloudkitchen/templates/` | 52 template files |
| `docker/docker-compose.yml` | Local dev compose stack (same topology) |
| `scripts/seed.sh` | Database seed script |
| `scripts/seed-restaurants.sql` | Restaurant seed data |

**Services deployed**:
```
cloudkitchen namespace:
├── auth-service       (Go, :8080)  → JWT auth, user registration
├── user-service       (Go, :8080)  → User profiles
├── restaurant-service (Go, :8080)  → Restaurant management
├── menu-service       (Go, :8080)  → Menu items & categories
├── order-service      (Go, :8080)  → Order lifecycle, cart
├── payment-service    (Go, :8080)  → Payment processing
├── delivery-service   (Go, :8080)  → Delivery tracking
├── notification-service (Go, :8080) → Notifications (email/push)
├── frontend           (React/nginx, :8080) → SPA UI
├── postgres           (StatefulSet, :5432) → PostgreSQL 16
├── redis              (Deployment, :6379)  → Redis 7
└── nats               (StatefulSet, :4222) → NATS 2.10 + JetStream
```

### 6.1 Verify Image Registry Configuration

The `values.yaml` is **already configured for GCP** by default:

```yaml
# Already set correctly for GCP:
imageRegistry: us-central1-docker.pkg.dev/<PROJECT_ID>/cloudkitchen-registry
postgres:
  storageClass: standard-rwo   # GKE's built-in StorageClass (GCE PD CSI)
nats:
  storageClass: standard-rwo
```

> **KEY DIFFERENCE FROM AWS**: No need to change `storageClass` — GKE ships with `standard-rwo` (ReadWriteOnce, GCE Persistent Disk) out of the box. No EBS CSI driver addon needed.

### 6.2 ArgoCD Auto-Sync

ArgoCD's `app-cloudkitchen` Application auto-syncs once the root app is applied:

```bash
kubectl -n cloudkitchen get pods -w
# Wait for all pods to reach Running/Ready
```

### 6.3 Seed the Database

```bash
kubectl -n cloudkitchen port-forward svc/postgres 5432:5432 &
./scripts/seed.sh
```

### 6.4 Query the Database (Optional)

```bash
kubectl -n cloudkitchen exec -it postgres-0 -- psql -U postgres -d cloudkitchen

# Useful commands inside psql:
# \dn                        — list schemas
# \dt orders.*               — list tables in orders schema
# SELECT * FROM users.profiles;
# SELECT * FROM orders.orders;
```

### ✅ Layer 6 Validation

```bash
kubectl -n cloudkitchen get pods
# Expected: 9 service pods + postgres-0 + redis + nats-0

kubectl -n cloudkitchen get endpoints

curl -s http://$LB_IP/api/restaurants -H "Host: <your-domain>"
# Expected: 200 OK
```

---

## Layer 7 — Security Hardening

**What it does**: Applies Pod Security Standards, network policies, and leverages GKE's Workload Identity for IAM.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `security/pod-security.md` | Restricted PSS labels + compliant securityContext |
| `security/network-policies.yaml` | Default-deny + scoped allow rules |
| `security/secret.example.yaml` | Secret shape + External Secrets notes |
| `security/trivy.md` | CI scanning + trivy-operator |
| `.github/workflows/trivy-fs.yaml` | Filesystem-level Trivy scan workflow |

### 7.1 Apply Pod Security Standards

```bash
kubectl label namespace cloudkitchen \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite
```

### 7.2 Apply Network Policies

```bash
kubectl apply -f security/network-policies.yaml
```

### 7.3 Workload Identity (GKE-Native)

> **KEY DIFFERENCE FROM AWS**: GKE uses **Workload Identity** (built into the cluster, enabled by Terraform) instead of IRSA. No separate OIDC provider setup needed — it's automatic.

```bash
# Verify Workload Identity is enabled
gcloud container clusters describe cloudkitchen-dev \
  --zone us-central1-a \
  --format='value(workloadIdentityConfig.workloadPool)'
# Expected: <project_id>.svc.id.goog
```

### ✅ Layer 7 Validation

```bash
kubectl get networkpolicies -n cloudkitchen
# Expected: default-deny + allow rules

kubectl -n cloudkitchen logs deployment/auth-service-deployment --tail=5
# Expected: healthy JSON logs
```

---

## Layer 8 — Observability (Monitoring & Logging)

**What it does**: Deploys the full observability stack — Prometheus + Grafana + Alertmanager for metrics, Loki + Promtail for logs. All UIs exposed via Traefik sub-paths.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/apps/app-monitoring.yaml` | kube-prometheus-stack (GKE-tuned) |
| `argocd/apps/app-logging.yaml` | loki-stack ArgoCD Application |
| `monitoring/servicemonitor.yaml` | ServiceMonitor for 8 Go services |
| `monitoring/ingressroutes/` | Traefik IngressRoutes for Grafana, Prometheus, Alertmanager |
| `monitoring/dashboards/cloudkitchen-dashboards.yaml` | 8 per-service Grafana dashboards |
| `monitoring/prometheusrules.yaml` | Alert rules |
| `logging/loki-values.yaml` | Loki Helm values |
| `logging/promtail-values.yaml` | Promtail config |

> **GKE-SPECIFIC**: The monitoring Application (`app-monitoring.yaml`) disables `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy`, and `coreDns` scrapers because GKE manages these control-plane components and they aren't accessible from worker nodes.

### 8.1 Install Monitoring Stack

If ArgoCD root-app is deployed, it auto-syncs. Otherwise manually:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring
```

### 8.2 Install Logging Stack

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace logging

helm install loki grafana/loki -n logging -f logging/loki-values.yaml
helm install promtail grafana/promtail -n logging -f logging/promtail-values.yaml
```

### 8.3 Apply Monitoring Extras

```bash
kubectl apply -f monitoring/servicemonitor.yaml
kubectl apply -f monitoring/ingressroutes/
kubectl apply -f monitoring/dashboards/cloudkitchen-dashboards.yaml
kubectl apply -f monitoring/prometheusrules.yaml
```

### 8.4 Get Grafana Credentials

```bash
# Username: admin
kubectl get secret --namespace monitoring prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

### 8.5 Add Loki as Grafana Datasource

Already configured in `app-monitoring.yaml` via `additionalDataSources`:
- URL: `http://logging-loki.logging.svc.cluster.local:3100`

### ✅ Layer 8 Validation

```bash
kubectl -n monitoring get pods
# Expected: prometheus, grafana, alertmanager, node-exporter, kube-state-metrics

kubectl -n logging get pods
# Expected: loki, promtail (DaemonSet on each node)

echo "Grafana:      http://$LB_IP/grafana"
echo "Prometheus:   http://$LB_IP/prometheus"
echo "Alertmanager: http://$LB_IP/alertmanager"
```

---

## Layer 9 — TLS / HTTPS (cert-manager + Let's Encrypt)

**What it does**: Installs cert-manager, creates a ClusterIssuer, requests a TLS certificate, and switches all routes to HTTPS.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/apps/app-cert-manager.yaml` | cert-manager ArgoCD Application (v1.15.3) |
| `security/cert-manager/clusterissuer.yaml` | Let's Encrypt staging + prod ClusterIssuers |
| `security/cert-manager/certificate.yaml` | TLS cert → cloudkitchen-tls Secret |
| `monitoring/http-to-https-redirect.yaml` | HTTP → HTTPS redirect middleware |

### 9.1 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
```

### 9.2 Create ClusterIssuer

```bash
# Edit security/cert-manager/clusterissuer.yaml — set your email address
kubectl apply -f security/cert-manager/clusterissuer.yaml
```

### 9.3 Request Certificate

```bash
# Edit security/cert-manager/certificate.yaml — set your domain
kubectl apply -f security/cert-manager/certificate.yaml

# Wait for issuance (~3–5 minutes)
kubectl describe certificate cloudkitchen-tls -n cloudkitchen
```

### 9.4 Switch to HTTPS

```bash
# Update helm/cloudkitchen/values.yaml:
#   ingress.tls: true
#   ingress.entryPoint: websecure

git add helm/cloudkitchen/values.yaml
git commit -m "security: enforce HTTPS via cert-manager"
git push

# Apply HTTP → HTTPS redirect
kubectl apply -f monitoring/http-to-https-redirect.yaml
```

### ✅ Layer 9 Validation

```bash
kubectl get certificate -n cloudkitchen
# Expected: cloudkitchen-tls, Ready=True

curl -I https://your-domain.com
# Expected: HTTP/2 200, valid TLS certificate
```

---

## Layer 10 — DNS & Go-Live

**What it does**: Points your domain to the GCP Load Balancer IP, validates end-to-end traffic flow, and delivers the application live to end users.

### 10.1 Configure DNS

In your DNS registrar (GoDaddy, Cloudflare, etc.):

| Type | Name | Value | TTL |
|------|------|-------|-----|
| **A** | `cloudkitchen` (or `@`) | `<TRAEFIK_LB_IP>` | 1 Hour |

> **KEY DIFFERENCE FROM AWS**: GCP assigns a static **IP**, so use an **A record** (not CNAME). This also works for apex/root domains without special flattening.

### 10.2 Validate Host-Header Routing

```bash
curl -i "http://$LB_IP/api/restaurants" -H "Host: your-domain.com"
# Expected: 200 OK
```

### 10.3 Update Helm Values with Final Domain

```yaml
# In helm/cloudkitchen/values.yaml set:
ingress:
  host: your-domain.com
  lbIP: <LB_IP for debug access>
```

```bash
git add helm/cloudkitchen/values.yaml
git commit -m "config: finalize production domain"
git push
```

### ✅ Layer 10 Validation — Full End-to-End

| Endpoint | URL | Expected |
|----------|-----|----------|
| **Frontend** | `https://your-domain.com` | React SPA loads |
| **Auth API** | `https://your-domain.com/api/auth/health` | `200 OK` |
| **Restaurants API** | `https://your-domain.com/api/restaurants` | JSON response |
| **ArgoCD** | `https://your-domain.com/argocd` | ArgoCD login page |
| **Grafana** | `https://your-domain.com/grafana` | Grafana dashboards |
| **Prometheus** | `https://your-domain.com/prometheus` | Prometheus UI |

---

## 🧹 Teardown

When you need to stop billing:

```bash
# 1. Uninstall Helm releases
helm uninstall -n traefik traefik
helm uninstall -n argo argocd
helm uninstall -n monitoring prometheus
helm uninstall -n logging loki promtail
helm uninstall -n cert-manager cert-manager

# 2. Delete PVCs (to release Persistent Disks)
kubectl delete pvc --all -n cloudkitchen
kubectl delete pvc --all -n monitoring
kubectl delete pvc --all -n logging

# 3. Destroy GCP infrastructure
cd gcp-terraform
terraform destroy -auto-approve
```

> **WARNING**: `terraform destroy` will delete the GKE cluster, VPC, Artifact Registry (including all images), bastion, and all associated resources. This is irreversible.

---

## 📊 Cost Estimate (Dev Environment)

| Resource | Cost/Day |
|----------|----------|
| GKE Control Plane (zonal) | **FREE** ($74.40/mo credit) |
| 2x e2-medium nodes | ~$2.20 |
| Cloud NAT | ~$1.00 |
| Persistent Disks (PVCs) | ~$0.20 |
| TCP Load Balancer (Traefik) | ~$0.60 |
| Artifact Registry storage | ~$0.05 |
| Bastion (e2-small) | ~$0.40 |
| **Total** | **~$4–6/day** |

> **GCP is ~40% cheaper** for this dev setup because the zonal GKE control plane is free.

---

## 🔄 AWS ↔ GCP Key Differences Summary

| Aspect | AWS (EKS) | GCP (GKE) |
|--------|-----------|-----------|
| **Control plane cost** | ~$3.30/day | **FREE** (zonal, $74.40/mo credit) |
| **Provisioning time** | ~15–20 min | ~6–10 min |
| **Container registry** | ECR (1 repo per service) | Artifact Registry (1 shared repo) |
| **Load Balancer type** | NLB → **hostname** → CNAME | TCP LB → **static IP** → A record |
| **IAM for workloads** | IRSA (OIDC provider + IAM roles) | Workload Identity (built-in) |
| **PVC StorageClass** | `gp3` (EBS CSI addon required) | `standard-rwo` (built-in) |
| **Bastion access** | SSM Session Manager | IAP tunnel |
| **Node types** | t4g.medium (Arm) | e2-medium (x86) |
| **Managed scraping** | etcd/scheduler scraping works | Must disable (GKE manages CP) |
| **CI workflow file** | `.github/workflows/ci.yaml` | `.github/workflows/ci-gcp.yaml` |
| **Terraform state** | Local (S3 backend commented) | GCS backend (configured) |

---

## 📁 Quick Reference — All GCP Codebase Paths

```
cloudkitchen-app/
├── gcp-terraform/              ← Layer 1: IaC
│   ├── main.tf                 ← Root module (VPC → GKE → AR → Bastion)
│   ├── modules/{vpc,gke,artifact-registry,firewall,bastion}/
│   ├── terraform.tfvars        ← Your values (project_id, region, etc.)
│   └── outputs.tf              ← Cluster info, AR URLs, bastion SSH cmd
├── .github/workflows/
│   ├── ci-gcp.yaml             ← Layer 3: GCP CI pipeline
│   └── trivy-fs.yaml           ← Layer 7: Filesystem scanning
├── helm/cloudkitchen/          ← Layer 6: Umbrella Helm chart
│   ├── values.yaml             ← Service images, ports, DB, ingress (GCP-configured)
│   └── templates/ (52 files)   ← All K8s manifests
├── argocd/                     ← Layer 5: GitOps
│   ├── root-app.yaml           ← App-of-Apps root
│   ├── project.yaml            ← AppProject guardrails
│   └── apps/                   ← 5 child Applications (GKE-tuned monitoring)
├── monitoring/                 ← Layer 8: Observability extras
├── logging/                    ← Layer 8: Loki + Promtail values
├── security/                   ← Layers 7 + 9: PSS, NetworkPolicies, cert-manager, Trivy
├── scripts/                    ← Helpers (kubeconfig, build, seed, port-forward)
└── {auth,user,...}-service/    ← Layer 3: Per-service Dockerfiles + Go source
```
