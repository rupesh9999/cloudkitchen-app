# 🚀 CloudKitchen — AWS EKS End-to-End Live Deployment Guide

This is a comprehensive, step-by-step guide to deploying the **CloudKitchen** microservice application onto **AWS EKS** (Elastic Kubernetes Service) from scratch. It consolidates all 7 setup phases into a single sequential walkthrough, covering infrastructure provisioning, Traefik ingress, CI/CD, GitOps with ArgoCD, DNS configuration, observability, and HTTPS with cert-manager.

---

## 🏗️ Architecture & Deployment Flow

```
        🌐  https://cloudkitchen.<your-domain>            <- your app UI
        🌐  https://cloudkitchen.<your-domain>/argocd     <- ArgoCD UI
        🌐  https://cloudkitchen.<your-domain>/grafana    <- Grafana dashboards
        🌐  https://cloudkitchen.<your-domain>/prometheus <- Prometheus UI
                              │
                              ▼
                    ┌──────────────────┐
                    │ AWS Network LB   │  (Traefik service)
                    └────────┬─────────┘
                             ▼
              ┌────────────────────────────┐
              │  EKS cluster (us-east-1)   │
              │                            │
              │  Traefik  →  cloudkitchen ns│
              │  (HTTPS)     (8 svcs + UI + │
              │               PG + Redis +  │
              │               NATS)         │
              │                            │
              │  ArgoCD       (GitOps)     │
              │  Prometheus/Grafana (obs)  │
              │  Loki/Promtail (logs)      │
              │  cert-manager (TLS)        │
              └────────────────────────────┘
                             ▲
                             │  GitOps sync
                ┌────────────┴────────────┐
                │ GitHub repo (this one)  │
                │  CI builds & pushes →   │
                │  ECR + bumps values.yaml│
                └─────────────────────────┘
```

---

## 📋 Prerequisites & Tools

Before you begin, ensure you have the following tools installed locally:
- **AWS CLI v2** configured with administrator credentials (run `aws configure`).
- **Terraform ≥ 1.5**
- **kubectl**
- **Helm v3**
- A **domain name** (GoDaddy, Route53, etc.) where you can edit DNS records.

---

## 🗂️ Step-by-Step Deployment Runbook

### Phase 1 — Infrastructure & Bastion Provisioning

We use Terraform to set up the base VPC, EKS cluster, node groups, ECR registries, IAM roles, and a bastion (jump VM) to securely access the cluster.

#### 1.1 Provision the AWS Resources
Move to the `aws-terraform` directory, initialize Terraform, check the plan, and apply it.

```bash
cd aws-terraform
terraform init
terraform plan
terraform apply -auto-approve
```
*Note: The apply command takes about 15–20 minutes to complete because the EKS control plane provisioning takes time.*

#### 1.2 Update local kubeconfig
Generate the local kubeconfig context to allow `kubectl` to communicate with the newly created cluster.

```bash
aws eks update-kubeconfig --region us-east-1 --name cloudkitchen-dev
```

Verify you can contact the cluster:
```bash
kubectl get nodes
```
*(Expect 2 worker nodes in `Ready` state).*

#### 1.3 Access the Cluster via the Bastion Host (Optional)
SSM Session Manager can be used to securely shell into the bastion without needing port 22 open or managing SSH keys.

Identify the bastion EC2 instance ID and start an SSM session:
```bash
BASTION_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*bastion*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

aws ssm start-session --target $BASTION_ID
```
Once inside, become root and install the client tools:
```bash
sudo su -
# AWS CLI v2
yum install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && ./aws/install
# kubectl
curl -sLO "https://dl.k8s.io/release/v1.30.5/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/
# Helm
curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Map the bastion role to EKS cluster administration (run from your **local machine**):
```bash
BASTION_ROLE=$(terraform -chdir=terraform output -raw bastion_role_arn 2>/dev/null \
  || aws iam get-instance-profile \
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

---

### Phase 2 — Traefik Ingress Controller Setup

We install **Traefik** as our ingress controller to act as the single entrypoint into the cluster.

#### 2.1 Add Helm Repository & Create Namespace
```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
kubectl create namespace ingress
```

#### 2.2 Define Values & Install Traefik
Create the configuration values file to provision an AWS Network Load Balancer (NLB):

```bash
cat <<EOF > /tmp/traefik-values.yaml
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

helm install traefik traefik/traefik -n ingress -f /tmp/traefik-values.yaml
```

Wait until the load balancer is provisioned and capture the AWS LB hostname:
```bash
kubectl -n ingress get svc traefik -w
```
*(Press `Ctrl-C` once `EXTERNAL-IP` lists your ELB hostname)*

```bash
LB_DNS=$(kubectl -n ingress get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Your Traefik LB Hostname: $LB_DNS"
```

---

### Phase 3 — GitHub Actions CI/CD Configuration

We set up a GitHub Actions workflow to build and push container images to ECR, and update the deployment tags inside our Helm values.

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

#### 3.2 Create ECR Access User for CI
Create a dedicated IAM user with minimal permissions to push to ECR:
```bash
# Create user
aws iam create-user --user-name cloudkitchen-ci

# Attach policy
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
  --policy-name cloudkitchen-ci-ecr --policy-document file:///tmp/cloudkitchen-ci-policy.json

# Create keys
aws iam create-access-key --user-name cloudkitchen-ci
```
*Note the returned `AccessKeyId` and `SecretAccessKey`.*

#### 3.3 Set up GitHub Secrets & Variables
Navigate to your GitHub repository **Settings → Secrets and variables → Actions** and add:

**Secrets:**
* `AWS_ACCESS_KEY_ID`: Your IAM CI access key ID.
* `AWS_SECRET_ACCESS_KEY`: Your IAM CI secret access key.
* `GITOPS_TOKEN` (optional): A GitHub Personal Access Token (PAT) with `contents: write` permissions if branch protection rules are active.

**Variables:**
* `ECR_REGISTRY`: `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com`

#### 3.4 Trigger the CI Run
Commit a change to trigger the build workflow:
```bash
git commit --allow-empty -m "ci: trigger build"
git push
```
The workflow will compile all Go services and the React frontend in parallel, run a Trivy CVE security scan, push the images to ECR, and automatically write the new tags back to `helm/cloudkitchen/values.yaml` in a commit.

---

### Phase 4 — GitOps Deployment with ArgoCD

We deploy ArgoCD to sync the Helm chart configurations directly into the EKS cluster.

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
Create the `IngressRoute` to expose ArgoCD through the existing Traefik Ingress:
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
You can now access the dashboard by browsing `http://<LB_DNS>/argocd` and logging in as `admin`.

#### 4.3 Configure and Deploy CloudKitchen App-of-Apps
Modify the target Git repository in `argocd/root-application.yaml` to point to your repository URL. Then apply the application configuration:

```bash
# Update the repoURL inside the yaml before applying
kubectl apply -f argocd/root-app.yaml
```
ArgoCD will automatically auto-discover the Helm charts, pull the built Docker images from ECR, and orchestrate all 12 microservice pods.

---

### Phase 5 — DNS Mapping Setup

Verify endpoints and point your GoDaddy/DNS registrar CNAME records to the AWS NLB.

#### 5.1 Local Host Header Validation
Test that the routing configuration functions as expected by overriding the host header:
```bash
curl -i "http://$LB_DNS/api/restaurants" -H "Host: cloudkitchen.example.com"
```
*(Expect a `200 OK` status with a blank JSON array `[]`)*

#### 5.2 Configure CNAME Record in DNS
In your DNS registrar, add a new record:
* **Type:** `CNAME`
* **Name:** `cloudkitchen`
* **Value:** `<YOUR_TRAEFIK_LB_HOSTNAME>` (e.g., `a123-456.elb.us-east-1.amazonaws.com`)
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
git commit -m "config: update ingress domain to real URL"
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

### Phase 7 — HTTPS & Path-Routed Sub-Apps (Production Security)

We set up cert-manager to automatically fetch and renew free certificates from Let's Encrypt, and flip Traefik to serve all traffic over secure HTTPS connections.

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
cat <<EOF > /tmp/letsencrypt-issuer.yaml
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

kubectl apply -f /tmp/letsencrypt-issuer.yaml
```

#### 7.3 Request Certificate
Create the certificate resource representing your domain name:
```bash
cat <<EOF > /tmp/cloudkitchen-cert.yaml
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

kubectl apply -f /tmp/cloudkitchen-cert.yaml
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
cat <<EOF > /tmp/https-redirect-middleware.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: ingress
spec:
  redirectScheme:
    scheme: https
    permanent: true
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: http-catchall
  namespace: ingress
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

kubectl apply -f /tmp/https-redirect-middleware.yaml
```

Update monitoring and dashboard routes to require HTTPS:
```bash
cat <<EOF > /tmp/secure-ingressroutes.yaml
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

kubectl apply -f /tmp/secure-ingressroutes.yaml
```

You can now access your application secure interface:
* Main App UI: `https://cloudkitchen.yourdomain.com`
* ArgoCD UI: `https://cloudkitchen.yourdomain.com/argocd`
* Grafana: `https://cloudkitchen.yourdomain.com/grafana`
* Prometheus: `https://cloudkitchen.yourdomain.com/prometheus`

---

## 🧹 Tearing Down the Infrastructure

If you need to stop billing, run the following commands to delete the resources from AWS.
```bash
# 1. Clean up Helm charts
helm uninstall -n ingress traefik
helm uninstall -n argo argocd
helm uninstall -n monitoring prometheus
helm uninstall -n logging loki promtail
helm uninstall -n cert-manager cert-manager

# 2. Destroy AWS resources via Terraform
cd aws-terraform
terraform destroy -auto-approve
```
