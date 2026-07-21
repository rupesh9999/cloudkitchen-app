# ☁️ CloudKitchen — AWS Execution Plan

> **Cloud**: AWS (us-east-1) · **Orchestration**: EKS · **Registry**: ECR
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
Layer  3 ──── CI/CD Pipeline (GitHub Actions → ECR → values.yaml)      │
Layer  2 ──── Cluster Access & Bastion Setup                           │
Layer  1 ──── Cloud Infrastructure (Terraform: VPC, EKS, ECR, IAM)     │
             ▲ FOUNDATION ─────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Minimum Version | Verify Command |
|------|----------------|----------------|
| AWS CLI | v2.x | `aws --version` |
| Terraform | ≥ 1.5 | `terraform -version` |
| kubectl | ≥ 1.28 | `kubectl version --client` |
| Helm | v3.x | `helm version` |
| Docker | ≥ 24.x | `docker --version` |
| Git | ≥ 2.x | `git --version` |

```bash
# Verify AWS credentials are configured
aws sts get-caller-identity
```

---

## Layer 1 — Cloud Infrastructure (Terraform)

**What it provisions**: VPC, public/private subnets across 3 AZs, NAT Gateway, Internet Gateway, route tables, IAM roles (cluster + node + IRSA), EKS control plane, managed node group, ECR repositories (9 services), bastion EC2 instance, security groups, EBS CSI driver addon.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `aws-terraform/provider.tf` | Terraform + AWS provider config, optional S3 backend |
| `aws-terraform/variables.tf` | All variable declarations |
| `aws-terraform/terraform.tfvars` | Actual values (region, node sizes, CIDRs) |
| `aws-terraform/main.tf` | Root module wiring all 6 child modules + EBS CSI addon |
| `aws-terraform/outputs.tf` | Cluster endpoint, ECR URLs, kubeconfig cmd, IRSA ARNs |
| `aws-terraform/modules/vpc/` | VPC, 3 public + 3 private subnets, NAT, IGW, routes |
| `aws-terraform/modules/iam/` | Cluster role, node role, IRSA roles (LB controller, external-dns, cert-manager, EBS CSI) |
| `aws-terraform/modules/security-groups/` | Bastion SG, worker SG, control plane SG |
| `aws-terraform/modules/eks/` | EKS cluster + managed node group + OIDC provider |
| `aws-terraform/modules/ecr/` | 9 ECR private repositories (one per microservice) |
| `aws-terraform/modules/bastion/` | EC2 jump host in public subnet |

**Infrastructure topology**:
```
VPC 10.10.0.0/16  (us-east-1)
├── Public Subnets  (10.10.0.0/20, .16.0/20, .32.0/20)  → NAT GW, Bastion, LB
├── Private Subnets (10.10.48.0/20, .64.0/20, .80.0/20) → EKS worker nodes
├── Internet Gateway
├── NAT Gateway (single, cost-optimized)
└── Route Tables (public → IGW, private → NAT)

EKS Cluster: cloudkitchen-dev (K8s 1.35)
├── 3x t4g.medium worker nodes (Arm, cost-effective)
├── OIDC provider (for IRSA)
└── EBS CSI Driver addon (for PVC-backed StatefulSets)

ECR: 9 repositories (auth-service, user-service, restaurant-service,
     menu-service, order-service, payment-service, delivery-service,
     notification-service, frontend)
```

### 1.1 Review & Customize Variables

```bash
cd aws-terraform

# Review the values — adjust region, node counts, CIDRs, bastion key if needed
cat terraform.tfvars
```

> **IMPORTANT**: Before production — tighten `endpoint_public_access_cidrs` and `bastion_allowed_cidrs` to your office IP. Set `single_nat_gateway = false` for HA.

### 1.2 Initialize & Apply Terraform

```bash
terraform init
terraform plan          # review the 40+ resources to be created
terraform apply -auto-approve
```

> ⏱️ **ETA**: ~15–20 minutes (EKS control plane provisioning is the bottleneck)

### 1.3 Capture Outputs

```bash
# Save key outputs for downstream layers
terraform output cluster_name
terraform output ecr_repository_urls
terraform output kubeconfig_command
terraform output irsa_role_arns
terraform output bastion_public_ip
```

### ✅ Layer 1 Validation

```bash
aws eks describe-cluster --name cloudkitchen-dev --query 'cluster.status'
# Expected: "ACTIVE"

aws ecr describe-repositories --query 'repositories[].repositoryName'
# Expected: 9 repository names
```

---

## Layer 2 — Cluster Access & Bastion Setup

**What it does**: Configures local `kubectl` to talk to EKS, optionally sets up the bastion as a second control point.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `scripts/kubeconfig.sh` | Helper script to update kubeconfig + verify |

### 2.1 Update Local Kubeconfig

```bash
# Use the exact command from Terraform output
aws eks update-kubeconfig --region us-east-1 --name cloudkitchen-dev

# Or use the helper script
./scripts/kubeconfig.sh
```

### 2.2 Verify Cluster Connectivity

```bash
kubectl get nodes -o wide
# Expected: 3 nodes in Ready state (t4g.medium, arm64)

kubectl get ns
# Expected: default, kube-system, kube-public, kube-node-lease
```

### 2.3 Bastion Access (Optional)

```bash
# Get bastion instance ID
BASTION_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*bastion*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

# Connect via SSM (no SSH keys needed)
aws ssm start-session --target $BASTION_ID

# Inside bastion — install tools (ARM64 / Graviton for t4g.micro):
sudo su -
yum install -y unzip
rm -rf aws awscliv2.zip
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && ./aws/install --update
curl -sLO "https://dl.k8s.io/release/v1.35.0/bin/linux/arm64/kubectl"
install -m 0755 kubectl /usr/local/bin/kubectl
curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 2.4 Grant Bastion EKS Access

```bash
# Enable Access Entries API on the cluster if not already set:
aws eks update-cluster-config \
  --name cloudkitchen-dev \
  --access-config authenticationMode=API_AND_CONFIG_MAP

# Map the bastion's IAM role to EKS admin (run from local machine)
BASTION_ROLE=$(aws iam get-instance-profile \
  --instance-profile-name cloudkitchen-dev-bastion-profile \
  --query 'InstanceProfile.Roles[0].Arn' --output text)

aws eks create-access-entry \
  --cluster-name cloudkitchen-dev \
  --principal-arn "$BASTION_ROLE" \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name cloudkitchen-dev \
  --principal-arn "$BASTION_ROLE" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

### ✅ Layer 2 Validation

```bash
kubectl cluster-info
# Expected: Kubernetes control plane is running at https://<endpoint>

kubectl get nodes
# Expected: 3 nodes, all Ready
```

---

## Layer 3 — CI/CD Pipeline (GitHub Actions → ECR)

**What it does**: Configures GitHub Actions to build all 9 service Docker images in parallel, scan them with Trivy (security gate), push to ECR, and commit updated image tags back to the Helm values file.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `.github/workflows/ci.yaml` | AWS/ECR CI pipeline (matrix build + GitOps update) |
| `scripts/build-images.sh` | Local image build helper script |
| `helm/cloudkitchen/values.yaml` | Image tags updated by CI's `update-gitops` job |
| Each service's `Dockerfile` | Per-service build definitions |

**CI pipeline flow**:
```
git push to main
    └── build (9x parallel matrix)
         ├── docker build (buildx, cached)
         ├── Trivy scan (HIGH/CRITICAL → FAIL)
         └── docker push → ECR  (sha + latest tags)
    └── update-gitops (runs after all builds pass)
         ├── yq patches values.yaml with new image:tag strings
         └── git commit + push "[skip ci]"
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

### 3.2 Create ECR CI User

```bash
# Create dedicated IAM user for CI
aws iam create-user --user-name cloudkitchen-ci

# Attach ECR push policy
cat <<EOF > /tmp/cloudkitchen-ci-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
EOF
aws iam put-user-policy --user-name cloudkitchen-ci \
  --policy-name cloudkitchen-ci-ecr \
  --policy-document file:///tmp/cloudkitchen-ci-policy.json

# Generate access keys (save the output!)
aws iam create-access-key --user-name cloudkitchen-ci
```

### 3.3 Configure GitHub Secrets & Variables

Navigate to **GitHub → Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|------|------|-------|
| **Secret** | `AWS_ACCESS_KEY_ID` | IAM CI access key |
| **Secret** | `AWS_SECRET_ACCESS_KEY` | IAM CI secret key |
| **Secret** | `GITOPS_TOKEN` | *(optional)* PAT with `contents:write` |
| **Variable** | `ECR_REGISTRY` | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com` |

### 3.4 Enable & Trigger the Pipeline

```bash
# In .github/workflows/ci.yaml — uncomment the push/pull_request triggers
# Then trigger:
git commit --allow-empty -m "ci: trigger first AWS build"
git push
```

### ✅ Layer 3 Validation

```bash
# Check GitHub Actions tab — all 9 build jobs should pass
# Check ECR has images:
aws ecr list-images --repository-name cloudkitchen-dev/auth-service
# Expected: imageIds with sha tags

# Verify values.yaml was auto-updated:
grep "image:" helm/cloudkitchen/values.yaml | head -5
# Expected: ECR URLs with short SHA tags
```

---

## Layer 4 — Ingress Controller (Traefik)

**What it does**: Deploys Traefik as the single ingress entrypoint, provisioning an AWS Network Load Balancer (NLB) to route external traffic into the cluster.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/apps/app-traefik.yaml` | ArgoCD Application for Traefik (used in Layer 5) |
| `helm/cloudkitchen/templates/ingressroute.yaml` | Per-service path routing rules |

### 4.1 Install Traefik via Helm

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

cat <<EOF > /tmp/traefik-values-aws.yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
ports:
  web:
    port: 80
    expose:
      default: true
    exposedPort: 80
    protocol: TCP
  websecure:
    port: 443
    expose:
      default: true
    exposedPort: 443
    protocol: TCP
ingressClass:
  enabled: true
  isDefaultClass: true
deployment:
  replicas: 2
ingressRoute:
  dashboard:
    enabled: true
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
EOF

helm install traefik traefik/traefik \
  --namespace ingress --create-namespace \
  -f /tmp/traefik-values-aws.yaml
```

### 4.2 Capture the Load Balancer Hostname

```bash
# Wait for LB provisioning
kubectl -n ingress get svc traefik -w

# Capture hostname (AWS NLB uses hostname, not IP)
LB_DNS=$(kubectl -n ingress get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Traefik NLB: $LB_DNS"
```

### ✅ Layer 4 Validation

```bash
kubectl -n ingress get pods
# Expected: 2 traefik pods Running

curl -s -o /dev/null -w "%{http_code}" http://$LB_DNS
# Expected: 404 (no routes configured yet — that's correct)
```

---

## Layer 5 — GitOps Engine (ArgoCD)

**What it does**: Installs ArgoCD, exposes it via Traefik at `/argocd`, creates the AppProject, and bootstraps the App-of-Apps pattern that will manage all subsequent deployments.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/project.yaml` | AppProject with allowed repos, namespaces, resource whitelist |
| `argocd/root-app.yaml` | Root Application (App-of-Apps) that fans out to child apps |
| `argocd/apps/app-cloudkitchen.yaml` | Child app: microservices (Helm chart) |
| `argocd/apps/app-traefik.yaml` | Child app: Traefik ingress |
| `argocd/apps/app-cert-manager.yaml` | Child app: cert-manager |
| `argocd/apps/app-monitoring.yaml` | Child app: kube-prometheus-stack |
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

### ✅ Layer 5 Validation

```bash
# Access ArgoCD UI
echo "http://$LB_DNS/argocd"
# Login: admin / <password from 5.3>

# CLI check:
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
| `helm/cloudkitchen/templates/` | 52 template files (deployments, services, configmaps, secrets, HPAs, StatefulSets, IngressRoute) |
| `docker/docker-compose.yml` | Local dev compose stack (same service topology) |
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

### 6.1 Switch Image Registry for AWS

Before ArgoCD syncs, update `helm/cloudkitchen/values.yaml`:

```yaml
# Replace GCP registry prefix with AWS ECR
imageRegistry: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/cloudkitchen-dev

# Update storageClass for EBS (EKS)
postgres:
  storageClass: gp3      # was: standard-rwo (GKE)
nats:
  storageClass: gp3      # was: standard-rwo (GKE)
```

```bash
git add helm/cloudkitchen/values.yaml
git commit -m "infra: switch registry to ECR + EBS storage class"
git push
```

### 6.2 ArgoCD Auto-Sync

ArgoCD's `app-cloudkitchen` Application auto-syncs on detecting the commit:

```bash
kubectl -n cloudkitchen get pods -w
# Wait for all pods to reach Running/Ready
```

### 6.3 Seed the Database

```bash
kubectl -n cloudkitchen port-forward svc/postgres 5432:5432 &
./scripts/seed.sh
```

### ✅ Layer 6 Validation

```bash
# All pods running
kubectl -n cloudkitchen get pods
# Expected: 9 service pods + postgres-0 + redis + nats-0

# Health checks
kubectl -n cloudkitchen get endpoints

# Quick API test
curl -s http://$LB_DNS/api/restaurants -H "Host: <your-domain>"
# Expected: 200 OK with restaurant data (or empty array)
```

---

## Layer 7 — Security Hardening

**What it does**: Applies Pod Security Standards, network policies (default-deny + scoped allows), and prepares secrets management.

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

### 7.3 IRSA Verification

```bash
terraform -chdir=aws-terraform output irsa_role_arns
# Expected: ARNs for aws_load_balancer_controller, external_dns, cert_manager, ebs_csi_driver
```

### ✅ Layer 7 Validation

```bash
kubectl get networkpolicies -n cloudkitchen
# Expected: default-deny-ingress, default-deny-egress, plus allow rules

kubectl -n cloudkitchen logs deployment/auth-service-deployment --tail=5
# Expected: healthy JSON logs, no connection errors
```

---

## Layer 8 — Observability (Monitoring & Logging)

**What it does**: Deploys the full observability stack — Prometheus + Grafana + Alertmanager for metrics, Loki + Promtail for logs. Exposes all UIs via Traefik sub-paths.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/apps/app-monitoring.yaml` | kube-prometheus-stack ArgoCD Application |
| `argocd/apps/app-logging.yaml` | loki-stack ArgoCD Application |
| `monitoring/servicemonitor.yaml` | ServiceMonitor for 8 Go services |
| `monitoring/ingressroutes/` | Traefik IngressRoutes for Grafana, Prometheus, Alertmanager |
| `monitoring/dashboards/cloudkitchen-dashboards.yaml` | 8 per-service Grafana dashboards |
| `monitoring/prometheusrules.yaml` | Alert rules (error-rate SLO, CrashLoopBackOff, latency) |
| `logging/loki-values.yaml` | Loki Helm values (single-binary, 7-day retention) |
| `logging/promtail-values.yaml` | Promtail config (JSON parse, cloudkitchen ns filter) |

### 8.1 Install Monitoring Stack

If ArgoCD root-app is already deployed with `app-monitoring.yaml`, it will auto-sync. Otherwise:

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

### ✅ Layer 8 Validation

```bash
kubectl -n monitoring get pods
# Expected: prometheus, grafana, alertmanager, node-exporter, kube-state-metrics

kubectl -n logging get pods
# Expected: loki, promtail (DaemonSet on each node)

echo "Grafana:      http://$LB_DNS/grafana"
echo "Prometheus:   http://$LB_DNS/prometheus"
echo "Alertmanager: http://$LB_DNS/alertmanager"
```

---

## Layer 9 — TLS / HTTPS (cert-manager + Let's Encrypt)

**What it does**: Installs cert-manager, creates a ClusterIssuer for Let's Encrypt, requests a TLS certificate, and switches all routes to HTTPS.

**Codebase files involved**:

| File | Purpose |
|------|---------|
| `argocd/apps/app-cert-manager.yaml` | cert-manager ArgoCD Application (v1.15.3) |
| `security/cert-manager/clusterissuer.yaml` | Let's Encrypt staging + prod ClusterIssuers |
| `security/cert-manager/certificate.yaml` | TLS cert for your domain → cloudkitchen-tls Secret |
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
# Edit security/cert-manager/certificate.yaml — set your domain in dnsNames
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

**What it does**: Points your domain to the AWS NLB, validates end-to-end traffic flow, and delivers the application live to end users.

### 10.1 Configure DNS

In your DNS registrar (GoDaddy, Route53, Cloudflare, etc.):

| Type | Name | Value | TTL |
|------|------|-------|-----|
| **CNAME** | `cloudkitchen` (or subdomain) | `<TRAEFIK_NLB_HOSTNAME>` | 1 Hour |

> **NOTE**: AWS NLB uses a **hostname** (not an IP), so you need a CNAME record. If you need an apex/root domain, use Route53 alias records or Cloudflare's CNAME flattening.

### 10.2 Validate Host-Header Routing

```bash
curl -i "http://$LB_DNS/api/restaurants" -H "Host: your-domain.com"
# Expected: 200 OK
```

### 10.3 Update Helm Values with Final Domain

```yaml
# In helm/cloudkitchen/values.yaml set:
ingress:
  host: your-domain.com
  lbIP: <NLB hostname for debug access>
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
helm uninstall -n ingress traefik
helm uninstall -n argo argocd
helm uninstall -n monitoring prometheus
helm uninstall -n logging loki promtail
helm uninstall -n cert-manager cert-manager

# 2. Delete PVCs (to release EBS volumes)
kubectl delete pvc --all -n cloudkitchen
kubectl delete pvc --all -n monitoring
kubectl delete pvc --all -n logging

# 3. Destroy AWS infrastructure
cd aws-terraform
terraform destroy -auto-approve
```

> **WARNING**: `terraform destroy` will delete the EKS cluster, VPC, ECR repos (including all images), bastion, and all associated resources. This is irreversible.

---

## 📊 Cost Estimate (Dev Environment)

| Resource | Cost/Day |
|----------|----------|
| EKS Control Plane | ~$3.30 |
| 3x t4g.medium nodes | ~$2.40 |
| NAT Gateway + data | ~$1.50 |
| EBS volumes (PVCs) | ~$0.30 |
| NLB (Traefik) | ~$0.60 |
| ECR storage | ~$0.10 |
| Bastion (t4g.micro) | ~$0.15 |
| **Total** | **~$8–10/day** |

---

## 📁 Quick Reference — All AWS Codebase Paths

```
cloudkitchen-app/
├── aws-terraform/              ← Layer 1: IaC
│   ├── main.tf                 ← Root module (VPC → EKS → ECR → IAM → Bastion)
│   ├── modules/{vpc,eks,ecr,iam,security-groups,bastion}/
│   ├── terraform.tfvars        ← Your values
│   └── outputs.tf              ← Cluster info, ECR URLs, IRSA ARNs
├── .github/workflows/
│   ├── ci.yaml                 ← Layer 3: AWS CI pipeline
│   └── trivy-fs.yaml           ← Layer 7: Filesystem scanning
├── helm/cloudkitchen/          ← Layer 6: Umbrella Helm chart
│   ├── values.yaml             ← Service images, ports, DB, ingress
│   └── templates/ (52 files)   ← All K8s manifests
├── argocd/                     ← Layer 5: GitOps
│   ├── root-app.yaml           ← App-of-Apps root
│   ├── project.yaml            ← AppProject guardrails
│   └── apps/                   ← 5 child Applications
├── monitoring/                 ← Layer 8: Observability extras
├── logging/                    ← Layer 8: Loki + Promtail values
├── security/                   ← Layers 7 + 9: PSS, NetworkPolicies, cert-manager, Trivy
├── scripts/                    ← Helpers (kubeconfig, build, seed, port-forward)
└── {auth,user,...}-service/    ← Layer 3: Per-service Dockerfiles + Go source
```
