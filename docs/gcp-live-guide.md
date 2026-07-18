# 🚀 CloudKitchen — GCP GKE End-to-End Live Deployment Guide

This is a comprehensive, step-by-step guide to deploying the **CloudKitchen** microservice application onto **GCP GKE** (Google Kubernetes Engine) from scratch. It consolidates all 8 setup phases into a single sequential walkthrough, covering infrastructure provisioning, Traefik ingress, CI/CD, GitOps with ArgoCD, DNS configuration, observability, HTTPS with cert-manager, and querying the database.

---

## 🏗️ Architecture & Deployment Flow

```
        🌐  https://cloudkitchen.<your-domain>             <- your app UI
        🌐  https://cloudkitchen.<your-domain>/argocd      <- ArgoCD UI
        🌐  https://cloudkitchen.<your-domain>/grafana     <- Grafana dashboards
        🌐  https://cloudkitchen.<your-domain>/prometheus  <- Prometheus UI
                              │
                              ▼
                    ┌──────────────────────┐
                    │ GCP TCP LoadBalancer │  (Traefik Service, single static IP)
                    └─────────┬────────────┘
                              ▼
              ┌────────────────────────────────┐
              │  GKE cluster (us-central1-a)   │
              │                                │
              │  Traefik  →  cloudkitchen ns   │
              │  (HTTPS)     (8 svcs + UI +    │
              │               PG + Redis +     │
              │               NATS)            │
              │                                │
              │  ArgoCD          (GitOps)      │
              │  Prometheus/Grafana (obs)      │
              │  Loki/Promtail   (logs)        │
              │  cert-manager    (TLS)         │
              └────────────────────────────────┘
                             ▲
                             │  GitOps sync
                ┌────────────┴───────────────┐
                │ GitHub repo (this one)     │
                │  CI builds & pushes →      │
                │  Artifact Registry +       │
                │  bumps values.yaml         │
                └────────────────────────────┘
```

---

## 📋 Prerequisites & Tools

Before you begin, ensure you have the following tools installed locally:
- **gcloud CLI** authenticated (run `gcloud auth login`).
- **Terraform ≥ 1.5**
- **kubectl**
- **Helm v3**
- A **domain name** (GoDaddy, Route53, etc.) where you can edit DNS records.

---

## 🗂️ Step-by-Step Deployment Runbook

### Phase 1 — Infrastructure & Bastion Provisioning (GCP)

We use Terraform to set up the VPC, subnets, GKE cluster, Artifact Registry, IAM bindings, and a bastion host (without public IP) accessible securely via Identity-Aware Proxy (IAP).

#### 1.1 Enable Required APIs
Enable GCP APIs in your project to allow Terraform to create resources:
```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iap.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicenetworking.googleapis.com \
  --project=<your-project-id>
```

#### 1.2 Configure Terraform
Move to the `gcp-terraform` folder and edit `terraform.tfvars`:
* Set `project_id = "<your-gcp-project-id>"`
* Add your email to `iap_allowed_users = ["user:you@gmail.com"]` (this authorizes your SSH session to the bastion).

#### 1.3 Initialize and Apply Terraform
```bash
cd gcp-terraform
terraform init
terraform plan
terraform apply -auto-approve
```
*Note: The apply command takes about 6–10 minutes to complete (faster than AWS EKS).*

#### 1.4 Update local kubeconfig
Fetch the GKE credentials to control the cluster from your machine:
```bash
eval "$(terraform output -raw kubeconfig_command)"
```
Verify the connection:
```bash
kubectl get nodes
```
*(Expect 2 worker nodes in `Ready` state).*

#### 1.5 Access the Bastion Host via IAP (Optional)
GCP Identity-Aware Proxy (IAP) lets you log into the bastion without managing SSH keys or public IPs:
```bash
eval "$(terraform output -raw bastion_ssh_command)"
```
Once inside, install GKE credentials plugins and DevOps tools:
```bash
sudo apt-get update
sudo apt-get install -y curl gnupg lsb-release ca-certificates apt-transport-https

# Install kubectl via gcloud
gcloud components install kubectl

# Install Helm v3
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

### Phase 2 — Traefik Ingress Controller Setup

We deploy **Traefik** in a dedicated `traefik` namespace, which provisions a GCP Regional TCP Load Balancer with a static external IP.

#### 2.1 Add Helm Repository & Install Traefik
```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Install Traefik
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

#### 2.2 Capture the External IP
Verify the Service is running and capture the Load Balancer IP:
```bash
kubectl -n traefik get svc traefik
LB_IP=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Your Traefik Load Balancer IP: $LB_IP"
```

---

### Phase 3 — GitHub Actions CI/CD Configuration

We configure a GitHub Actions workflow to build and push container images to GCP Artifact Registry, then update our Helm configuration.

#### 3.1 Push the Code to GitHub
Initialize your Git repository and push it to your private GitHub repo:
```bash
git init
git add .
git commit -m "initial import"
git branch -M main
git remote add origin https://github.com/<your-username>/cloudkitchen.git
git push -u origin main
```

#### 3.2 Create GCP Service Account for CI
Create a dedicated Service Account with writing privileges only for Artifact Registry:
```bash
PROJECT=<your-project-id>
SA=cloudkitchen-ci

# Create SA
gcloud iam service-accounts create ${SA} \
  --display-name="CloudKitchen GitHub Actions" \
  --project=${PROJECT}

# Bind role
gcloud projects add-iam-policy-binding ${PROJECT} \
  --member="serviceAccount:${SA}@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

# Generate Key
gcloud iam service-accounts keys create gcp-ci-sa.json \
  --iam-account=${SA}@${PROJECT}.iam.gserviceaccount.com
```
*Copy the contents of `gcp-ci-sa.json` and delete the local file (`shred -u gcp-ci-sa.json`).*

#### 3.3 Set up GitHub Secrets & Variables
Add the credentials under **Settings → Secrets and variables → Actions** in GitHub:

**Secrets:**
* `GCP_SA_KEY`: Paste the complete JSON key contents.
* `GITOPS_TOKEN` (optional): A PAT with write access if branch restrictions prevent automated commits.

**Variables:**
* `GCP_PROJECT_ID`: Your GCP project ID.

#### 3.4 Trigger the CI Run
Commit a change to trigger the build workflow:
```bash
git commit --allow-empty -m "ci: trigger build"
git push
```
The GKE workflow (`.github/workflows/ci-gcp.yaml`) compiles all microservices, runs a Trivy CVE security scan, pushes the output to GCP Artifact Registry, and updates `helm/cloudkitchen/values.yaml` with the new image tags.

---

### Phase 4 — GitOps Deployment with ArgoCD

We deploy ArgoCD to GKE and expose it securely under the `/argocd` sub-path.

#### 4.1 Install ArgoCD
Add the ArgoCD Helm repository, create a namespace, and deploy it:
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argo
```

Create a values file containing the path-routing configs (under `/argocd`):
```bash
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

#### 4.2 Route ArgoCD Through Traefik
Create the GCP-specific `IngressRoute` pointing to the ArgoCD server:
```bash
cat <<EOF > /tmp/argocd-ingressroute.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argo
spec:
  entryPoints:
    - web
  routes:
    - match: PathPrefix(\`/argocd\`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
EOF

kubectl apply -f /tmp/argocd-ingressroute.yaml
```

Retrieve the default admin password:
```bash
kubectl -n argo get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```
You can now access the dashboard by browsing `http://<LB_IP>/argocd` and logging in as `admin`.

#### 4.3 Configure and Deploy CloudKitchen App-of-Apps
Modify the target Git repository in `argocd/root-application.yaml` to point to your repository URL. Then apply the application configuration:

```bash
# Update the repoURL inside the yaml before applying
kubectl apply -f argocd/root-application.yaml
```
ArgoCD will sync the configs, deploy all microservices, and provision Postgres, Redis, and NATS.

---

### Phase 5 — DNS Mapping Setup

Verify endpoints and point your GoDaddy/DNS registrar CNAME records to the GCP TCP Load Balancer IP.

#### 5.1 Local Host Header Validation
Verify that the routing rules function properly:
```bash
curl -i "http://$LB_IP/api/restaurants" -H "Host: cloudkitchen.example.com"
```
*(Expect a `200 OK` status with a blank JSON array `[]`)*

#### 5.2 Configure A Record in DNS
In your DNS registrar, add a new record pointing your domain name:
* **Type:** `A`
* **Name:** `cloudkitchen`
* **Value:** `<YOUR_TRAEFIK_LB_IP>` (e.g., `35.224.38.103`)
* **TTL:** `1 Hour` (or minimum)

#### 5.3 Update Helm configuration to match your domain
Edit `helm/cloudkitchen/values.yaml` and set:
```yaml
ingress:
  domain: "cloudkitchen.yourdomain.com"
```
Commit and push the updates. ArgoCD will pick up the change within minutes:
```bash
git add helm/cloudkitchen/values.yaml
git commit -m "config: update ingress domain to real GKE IP"
git push
```
You can now reach your application via `http://cloudkitchen.yourdomain.com`.

---

### Phase 6 — Observability (Monitoring & Logging Stack)

We install Prometheus, Grafana, Loki, and Promtail to gather performance metrics and container logs.

#### 6.1 Install Prometheus and Grafana
Add the prometheus-community chart, create the `monitoring` namespace, and install the Prometheus operator stack:
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring

# Deploys Prometheus, Grafana, Node Exporter, and Alertmanager
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring
```

Configure sub-path routing rules through Traefik for Prometheus and Grafana:
```bash
cat <<EOF > /tmp/monitoring-ingressroutes.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  entryPoints:
    - web
  routes:
    - match: PathPrefix(\`/grafana\`)
      kind: Rule
      services:
        - name: prometheus-grafana
          port: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: prometheus
  namespace: monitoring
spec:
  entryPoints:
    - web
  routes:
    - match: PathPrefix(\`/prometheus\`)
      kind: Rule
      services:
        - name: prometheus-kube-prometheus-prometheus
          port: 9090
EOF

kubectl apply -f /tmp/monitoring-ingressroutes.yaml
```

Update the Grafana sub-path configuration:
```bash
kubectl edit configmap prometheus-grafana -n monitoring
```
Add the following settings under the `[server]` block:
```ini
root_url = %(protocol)s://%(domain)s:%(http_port)s/grafana/
serve_from_sub_path = true
```
Restart the Grafana deployment:
```bash
kubectl rollout restart deployment prometheus-grafana -n monitoring
```

Retrieve the default Grafana login credentials:
* **Username:** `admin`
* **Password:** Retrieve via:
  ```bash
  kubectl get secret --namespace monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
  ```

#### 6.2 Install Grafana Loki and Promtail
Add Grafana's Helm repository, create the `logging` namespace, and install the Loki logging stack:
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace logging

# Deploy Loki
helm install loki grafana/loki -n logging --set loki.auth_enabled=false

# Deploy Promtail to collect and stream logs
helm install promtail grafana/promtail -n logging --set config.clients[0].url=http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push
```
Add Loki as a Data Source in Grafana (`http://loki-gateway.logging.svc.cluster.local`) to begin querying microservice logs.

---

### Phase 7 — HTTPS via cert-manager + Let's Encrypt

We set up cert-manager to automatically fetch and renew free certificates from Let's Encrypt, and secure our Traefik routes.

#### 7.1 Install cert-manager
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager with CustomResourceDefinitions enabled
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

#### 7.2 Configure Let's Encrypt Issuers
Create the `ClusterIssuer` configurations:
```bash
cat <<EOF > /tmp/letsencrypt-issuer-gcp.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@yourdomain.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
EOF

kubectl apply -f /tmp/letsencrypt-issuer-gcp.yaml
```

#### 7.3 Request Certificate
Create the certificate resource representing your domain name:
```bash
cat <<EOF > /tmp/cloudkitchen-cert-gcp.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cloudkitchen-tls
  namespace: cloudkitchen
spec:
  secretName: cloudkitchen-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - cloudkitchen.yourdomain.com
EOF

kubectl apply -f /tmp/cloudkitchen-cert-gcp.yaml
```
Verify issues:
```bash
kubectl describe certificate cloudkitchen-tls -n cloudkitchen
```
*(Wait until status is `Ready: True` which takes about 3-5 minutes)*

#### 7.4 Reconfigure Traefik for HTTP Redirect & HTTPS Ingress
Modify `helm/cloudkitchen/values.yaml` to enable TLS and bind to `websecure` (port 443):
```yaml
ingress:
  domain: "cloudkitchen.yourdomain.com"
  tls: true
```
Commit and push:
```bash
git add helm/cloudkitchen/values.yaml
git commit -m "security: enforce HTTPS in values"
git push
```

Apply a catch-all middleware in Traefik to redirect all standard HTTP traffic to secure HTTPS:
```bash
cat <<EOF > /tmp/https-redirect-middleware-gcp.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: traefik
spec:
  redirectScheme:
    scheme: https
    permanent: true
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: http-catchall
  namespace: traefik
spec:
  entryPoints:
    - web
  routes:
    - match: HostRegexp(\`{host:.+}\`)
      kind: Rule
      middlewares:
        - name: redirect-to-https
      services:
        - name: noop
          port: 80
EOF

kubectl apply -f /tmp/https-redirect-middleware-gcp.yaml
```

Update monitoring and dashboard routes to require HTTPS:
```bash
cat <<EOF > /tmp/secure-ingressroutes-gcp.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-secure
  namespace: argo
spec:
  entryPoints:
    - websecure
  routes:
    - match: PathPrefix(\`/argocd\`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: cloudkitchen-tls
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: monitoring-secure
  namespace: monitoring
spec:
  entryPoints:
    - websecure
  routes:
    - match: PathPrefix(\`/grafana\`)
      kind: Rule
      services:
        - name: prometheus-grafana
          port: 80
    - match: PathPrefix(\`/prometheus\`)
      kind: Rule
      services:
        - name: prometheus-kube-prometheus-prometheus
          port: 9090
  tls:
    secretName: cloudkitchen-tls
EOF

kubectl apply -f /tmp/secure-ingressroutes-gcp.yaml
```

You can now access your application secure interface:
* Main App UI: `https://cloudkitchen.yourdomain.com`
* ArgoCD UI: `https://cloudkitchen.yourdomain.com/argocd`
* Grafana: `https://cloudkitchen.yourdomain.com/grafana`
* Prometheus: `https://cloudkitchen.yourdomain.com/prometheus`

---

### Phase 8 — PostgreSQL Database Operations

To inspect database schemas or run queries across the 8 microservices, query the GKE Postgres deployment.

#### 8.1 Connect to Postgres Pod
Run a shell inside the `postgres-0` pod:
```bash
kubectl -n cloudkitchen exec -it postgres-0 -- psql -U postgres -d cloudkitchen
```

#### 8.2 Useful Database Commands
* List schemas: `\dn`
* List tables in a specific schema: `\dt orders.*`
* Run queries:
  ```sql
  -- Check user profiles
  SELECT * FROM users.profiles;

  -- View orders placed
  SELECT * FROM orders.orders;

  -- View deliveries
  SELECT * FROM delivery.deliveries;
  ```

---

## 🧹 Tearing Down the Infrastructure

If you need to stop billing, run the following commands to delete the resources from GCP.
```bash
# 1. Clean up Helm charts
helm uninstall -n traefik traefik
helm uninstall -n argo argocd
helm uninstall -n monitoring prometheus
helm uninstall -n logging loki promtail
helm uninstall -n cert-manager cert-manager

# 2. Destroy GCP resources via Terraform
cd gcp-terraform
terraform destroy -auto-approve
```
