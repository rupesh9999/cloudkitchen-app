# Phase 7 — HTTPS with Let's Encrypt + Path-Routed Sub-Apps (GCP)

**Goal:** Install **cert-manager**, mint a free **Let's Encrypt** certificate
for your domain, flip the chart to **HTTPS** (`websecure` entryPoint), and
move ArgoCD + Grafana + Prometheus + Alertmanager over to HTTPS too — so
you finish with:

```
https://vijaygiduthuri.in                — the app UI
https://vijaygiduthuri.in/argocd         — ArgoCD UI
https://vijaygiduthuri.in/grafana        — Grafana
https://vijaygiduthuri.in/prometheus     — Prometheus
https://vijaygiduthuri.in/alertmanager   — Alertmanager
```

**Time:** ~15 minutes (most of it Let's Encrypt issuing the cert).

This is the **GCP counterpart** of [docs/eks/07-https-letsencrypt-and-routes.md](../eks/07-https-letsencrypt-and-routes.md).
Same architecture; only the install paths + service names differ.

---

## What & why

After Phase 5 you have HTTP working. Modern browsers warn on HTTP and many
auth flows (Grafana login form autofill, ArgoCD OAuth, etc.) refuse to run
over HTTP. So HTTPS is the next step.

**cert-manager** is the standard Kubernetes operator that talks to ACME
servers (Let's Encrypt, ZeroSSL, internal CA) to obtain + renew TLS
certificates automatically. We use Let's Encrypt's free public service
with the **HTTP-01** challenge: cert-manager creates a temporary IngressRoute
serving a token at `http://<your-domain>/.well-known/acme-challenge/…`,
Let's Encrypt fetches it to prove you control the domain, and emits a
90-day cert (renewed automatically at day 75).

```
        ┌──────────────────────────────────────────────────────┐
        │  cert-manager (cert-manager ns)                       │
        │   ┌─────────────────────────────────────────┐         │
        │   │  ClusterIssuer "letsencrypt-prod"        │         │
        │   └─────────────────────────────────────────┘         │
        │                       │                              │
        │                       ▼                              │
        │   Certificate "cloudkitchen-tls"  in cloudkitchen ns │
        │   → produces Secret "cloudkitchen-tls"                │
        └──────────────────────┬───────────────────────────────┘
                               │
                               ▼  (the Secret holds tls.crt + tls.key)
        Traefik IngressRoute (chart-rendered, ingress.tls=true)
        references secretName: cloudkitchen-tls  →  HTTPS!
```

---

## ⚠️ Heads-up — the Certificate is created manually

The cert-manager `Certificate` resource is **NOT** in the cloudkitchen
helm chart on purpose. The cert's lifecycle is tied to your **domain**,
not the chart's release lifecycle — keeping it separate makes it safer
to re-deploy the chart without churning the cert (Let's Encrypt
rate-limits real-cert issuance to 5/week per registered domain).

So in this phase we **apply the Certificate manifest by hand** from
`security/cert-manager/certificate.yaml`.

---

## ✅ Prerequisites

| Check | How |
|---|---|
| Phase 5 done (your domain resolves to the LB IP) | `dig +short vijaygiduthuri.in` → returns your LB IP (e.g. `136.112.45.103`) |
| Phase 6 done (monitoring + logging) | `kubectl -n monitoring get pods` healthy |
| Port 80 reachable from the internet | Used by Let's Encrypt for HTTP-01 challenge. Traefik listens on 80 by default. |
| `kubectl` + `helm` work | `kubectl get nodes` and `helm version` succeed |

> 💡 **Why port 80 has to stay open** — even after we flip the app to
> HTTPS, we keep port 80 reachable so cert-manager can solve the HTTP-01
> challenge during renewals. Traefik will redirect normal traffic from
> `:80` → `:443` (configured in Step 4) while still passing
> `/.well-known/acme-challenge/…` through to cert-manager's solver.

---

## Step 1 — Install cert-manager

Two equally valid paths. Pick one.

### Option A — As an ArgoCD Application (matches Phase 6 pattern)

The repo already ships [argocd/apps/app-cert-manager.yaml](../../argocd/apps/app-cert-manager.yaml).
**Three edits needed before applying** — each fixes a real ArgoCD AppProject
guardrail that bit us on the first try:

**Edit 1 (in `argocd/apps/app-cert-manager.yaml`):** the file targets the
`ingress` namespace by default, but Traefik already owns the `traefik`
namespace and cert-manager conventionally lives in its own `cert-manager`
namespace. Change the destination:

```yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager          # was: ingress
```

**Edit 2 (same file):** by default the chart creates its leader-election
`Role` + `RoleBinding` in `kube-system` — but our `cloudkitchen` AppProject's
`destinations:` list does **not** include `kube-system`, so ArgoCD rejects
the sync with `namespace kube-system is not permitted in project 'cloudkitchen'`.
Pin leader-election to the `cert-manager` namespace instead by adding inside
the `helm.values:` block:

```yaml
helm:
  values: |
    installCRDs: true
    replicaCount: 2
    # 👇 ADD THIS — keeps leader-election Roles/RoleBindings out of kube-system
    global:
      leaderElection:
        namespace: cert-manager
    # rest of values stay as they were
```

**Edit 3 (in `argocd/project.yaml`):** add `cert-manager` to the AppProject's
`destinations:` list — otherwise the App will fail with `namespace cert-manager
is not permitted in project 'cloudkitchen'`:

```yaml
  destinations:
    - server: https://kubernetes.default.svc
      namespace: cloudkitchen
    # ... existing entries ...
    - server: https://kubernetes.default.svc
      namespace: argocd
    # 👇 ADD THIS
    - server: https://kubernetes.default.svc
      namespace: cert-manager
```

Apply the updated AppProject first, then the App:

```bash
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/apps/app-cert-manager.yaml
```

ArgoCD auto-syncs, creates the `cert-manager` namespace, and installs the
chart. Wait until all 3 cert-manager Deployments are Ready (~70 s):

```bash
kubectl -n argocd get app cert-manager -w
# Wait until: Synced  Healthy

kubectl -n cert-manager get pods
# Expect 4 pods Running 1/1:
#   cert-manager-*            (×2 replicas)
#   cert-manager-cainjector-*
#   cert-manager-webhook-*
```

### Option B — Direct `helm install` (simpler one-off, no ArgoCD)

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set replicaCount=2 \
  --set global.leaderElection.namespace=cert-manager \
  --wait --timeout=5m
```

Either way: 3 cert-manager pods Running + 5 CRDs installed
(`certificates`, `certificaterequests`, `clusterissuers`, `issuers`,
`orders`, `challenges`).

```bash
kubectl get crd | grep cert-manager.io
kubectl -n cert-manager get pods
```

---

## Step 2 — Apply the Let's Encrypt ClusterIssuer

One ClusterIssuer, one apply.

**File:** [security/cert-manager/clusterissuer.yaml](../../security/cert-manager/clusterissuer.yaml).
Uses Let's Encrypt's production API + the HTTP-01 challenge via Traefik.

### Set your email (one edit)

Let's Encrypt requires a real email so they can warn you before a cert
expires. Open the file and change the `email:` field:

```yaml
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: vijaygiduthuri67@gmail.com   # 👈 YOUR real email
```

### Apply

```bash
kubectl apply -f security/cert-manager/clusterissuer.yaml
```

### Verify

```bash
kubectl get clusterissuer
# NAME               READY   AGE
# letsencrypt-prod   True    30s
```

If `READY=False`, the most likely cause is cert-manager pods aren't ready
yet (Step 1 wait). Re-run `kubectl -n cert-manager get pods` and confirm
all 4 are Running, then check:

```bash
kubectl describe clusterissuer letsencrypt-prod | tail -10
```

---

## Step 3 — Create the Certificate

One Certificate manifest, one apply, one wait.

**File:** [security/cert-manager/certificate.yaml](../../security/cert-manager/certificate.yaml).

### One edit — your domain

The shipped file uses `cloudkitchen.example.com` as a placeholder.
Replace it with your domain. The full block should look like:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cloudkitchen-tls
  namespace: cloudkitchen
spec:
  secretName: cloudkitchen-tls         # the Secret the chart will read
  duration: 2160h                       # 90 days (Let's Encrypt default)
  renewBefore: 360h                     # renew 15 days before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: letsencrypt-prod              # the ClusterIssuer from Step 2
    kind: ClusterIssuer
    group: cert-manager.io
  commonName: vijaygiduthuri.in         # 👈 YOUR domain
  dnsNames:
    - vijaygiduthuri.in                 # 👈 YOUR domain
```

### Apply

```bash
kubectl apply -f security/cert-manager/certificate.yaml
```

### Wait + verify

```bash
kubectl -n cloudkitchen get certificate cloudkitchen-tls -w
# Wait for READY=True. Typically 30-60 seconds.
```

Verify it's a real Let's Encrypt cert (issuer `Let's Encrypt`, not anything
else):

```bash
kubectl -n cloudkitchen get secret cloudkitchen-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -dates
# Expect:  issuer=C=US, O=Let's Encrypt, CN=YE1 (or R10/R11 — Let's Encrypt's intermediate CAs)
#          notBefore=...    notAfter=...
```

### If issuance is stuck

```bash
# Look at the Certificate's status conditions:
kubectl -n cloudkitchen describe certificate cloudkitchen-tls | tail -30

# Look at the active HTTP-01 challenge:
kubectl -n cloudkitchen get challenges
kubectl -n cloudkitchen describe challenge <name> | tail -30

# Most common cause: port 80 not reachable from the public internet so
# Let's Encrypt can't fetch http://your-domain/.well-known/acme-challenge/...
# Try it yourself:
curl -v http://vijaygiduthuri.in/.well-known/acme-challenge/test
# Expect: 404 (the challenge token doesn't exist yet — but the request reached Traefik).
# Connection refused / timeout = port 80 blocked upstream.
```

> 💡 **Heads up on Let's Encrypt rate limits**
> Let's Encrypt's production API limits you to **5 duplicate certificates
> per week per registered domain**. For a single-host learning project
> that's plenty — but if you're iterating and might hit it, you can switch
> to their staging API temporarily by changing the issuer's `server:` URL
> to `https://acme-staging-v02.api.letsencrypt.org/directory`. Staging is
> unlimited but emits certs your browser won't trust.

---

## Step 4 — Flip the chart to HTTPS

Edit [helm/cloudkitchen/values.yaml](../../helm/cloudkitchen/values.yaml) — change exactly two fields in the `ingress:` block:

```yaml
ingress:
  enabled: true
  tls: true                       # 👈 was: false
  host: vijaygiduthuri.in          # (unchanged from Phase 5)
  lbIP: 136.112.45.103              # (unchanged)
  entryPoint: websecure            # 👈 was: web
  tlsSecretName: cloudkitchen-tls   # (unchanged — points at the Secret from Step 3)
  clusterIssuer: letsencrypt-prod   # (unchanged)
```

Commit + push:
```bash
git add helm/cloudkitchen/values.yaml
git commit -m "phase 7: flip cloudkitchen ingress to HTTPS"
git push origin main
```

The pipeline rebuilds + pushes images and bumps tags (a `helm/**`
change triggers the full CI per our consolidated workflow — see Phase 3).
Then ArgoCD picks up the new values.yaml and reconciles. To skip the
3-minute poll wait:

```bash
kubectl -n argocd annotate app cloudkitchen \
  argocd.argoproj.io/refresh=hard --overwrite
```

Verify the IngressRoute now has TLS:

```bash
kubectl -n cloudkitchen get ingressroute cloudkitchen -o yaml \
  | grep -A 2 "tls:"
# Should show:  tls:
#                  secretName: cloudkitchen-tls
```

### Smoke test

```bash
curl -sI "https://vijaygiduthuri.in/" | head -1
# Expect: HTTP/2 200

curl -s "https://vijaygiduthuri.in/api/restaurants" | head -c 200 ; echo
# Expect: JSON array of restaurants
```

🎉 The app is now on **HTTPS with a real browser-trusted certificate**.

> ⚠️ HTTP-to-HTTPS redirect (port 80 → 443) is NOT automatic with the
> current chart. If you want plain `http://vijaygiduthuri.in/` to bounce
> to https, add this Traefik redirect Middleware and reference it on the
> route's `web` entrypoint — out of scope for this phase. Optional.

---

## Step 5 — Move ArgoCD / Grafana / Prometheus / Alertmanager to HTTPS

Right now those four UIs are reachable at `http://vijaygiduthuri.in/argocd/`,
`/grafana/`, `/prometheus/`, `/alertmanager/`. To move them to HTTPS, two
things change:

1. Each IngressRoute switches from `entryPoints: [web]` → `[websecure]` and
   gets a `tls: { secretName: cloudkitchen-tls }` block.
2. Because each IngressRoute lives in a **different namespace**
   (`monitoring`, `argocd`) and Traefik can only read the TLS Secret from
   the IngressRoute's own namespace, **we duplicate the Secret into each
   target namespace**.

### 5a — Duplicate the TLS Secret into `monitoring` and `argocd`

```bash
kubectl get secret cloudkitchen-tls -n cloudkitchen -o yaml \
  | sed 's/namespace: cloudkitchen/namespace: monitoring/' \
  | kubectl apply -f -

kubectl get secret cloudkitchen-tls -n cloudkitchen -o yaml \
  | sed 's/namespace: cloudkitchen/namespace: argocd/' \
  | kubectl apply -f -

# Verify
kubectl get secret cloudkitchen-tls -n monitoring
kubectl get secret cloudkitchen-tls -n argocd
```

> 💡 **About renewal** — cert-manager only refreshes the **original** Secret
> in the `cloudkitchen` namespace (the one tied to the `Certificate`
> resource). When the cert auto-renews (~day 75), you'll need to re-run
> the two `kubectl get | sed | apply` commands above to refresh the
> duplicates. For a learning project this is fine.
> If you want fully-automatic propagation, install
> [reflector](https://github.com/emberstack/kubernetes-reflector) and
> annotate the source Secret — out of scope here.

### 5b — Edit the 3 observability IngressRoutes

Open each file in [monitoring/ingressroutes/](../../monitoring/ingressroutes/)
and:

- Change `entryPoints: - web` → `entryPoints: - websecure`
- Add a `tls:` block at the bottom of `spec:`

The final shape for `monitoring/ingressroutes/grafana.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  entryPoints:
    - websecure                   # 👈 was: web
  routes:
    - match: Host(`vijaygiduthuri.in`) && PathPrefix(`/grafana`)
      kind: Rule
      services:
        - name: monitoring-grafana
          port: 80
  tls:                            # 👈 NEW block
    secretName: cloudkitchen-tls
```

Apply the same two edits to `prometheus.yaml` and `alertmanager.yaml`,
then `kubectl apply` all three:

```bash
kubectl apply -f monitoring/ingressroutes/
```

### 5c — Update the ArgoCD IngressRoute

The ArgoCD IngressRoute lives in the cluster (created via kubectl in
Phase 4, not in any chart). The easiest way to flip it to HTTPS is to
re-apply a corrected version:

```bash
cat > /tmp/argocd-ingressroute.yaml <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`vijaygiduthuri.in`) && PathPrefix(`/argocd`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: cloudkitchen-tls
EOF
kubectl apply -f /tmp/argocd-ingressroute.yaml
```

No `StripPrefix` middleware — ArgoCD was installed with
`configs.params.server.rootpath=/argocd` (Phase 4), so it already
expects the `/argocd` prefix on incoming requests.

---

## Step 6 — Verify all 5 URLs over HTTPS

```bash
DOMAIN=vijaygiduthuri.in

# 1. App UI
curl -sI "https://$DOMAIN/"                       | head -1
# Expect: HTTP/2 200

# 2. ArgoCD UI
curl -sIL "https://$DOMAIN/argocd/"               | head -1
# Expect: HTTP/2 200 (Argo redirects 307 → 200 with -L)

# 3. Grafana
curl -sIL "https://$DOMAIN/grafana/login"         | head -1
# Expect: HTTP/2 200

# 4. Prometheus
curl -sIL "https://$DOMAIN/prometheus/-/ready"    | head -1
# Expect: HTTP/2 200

# 5. Alertmanager
curl -sL  "https://$DOMAIN/alertmanager/-/ready"
# Expect: "OK"
```

Open each in a browser — you should see the **🔒 padlock** with a
browser-trusted (Let's Encrypt R10/R11 issuer) cert:

- https://vijaygiduthuri.in/                  → React UI
- https://vijaygiduthuri.in/argocd/           → ArgoCD UI (admin / your bootstrap password)
- https://vijaygiduthuri.in/grafana/          → Grafana (admin / prom-operator)
- https://vijaygiduthuri.in/prometheus/       → Prometheus
- https://vijaygiduthuri.in/alertmanager/     → Alertmanager

All five served over **HTTPS with a real browser-trusted certificate**. 🔒

---

## Step 7 — Redirect HTTP → HTTPS (catch-all)

If you `curl http://vijaygiduthuri.in/` right now you'll see:

```
404 page not found
```

That's because Step 4 + Step 5 moved every route to `entryPoints: [websecure]`
(port 443) — there's nothing listening on `entryPoints: [web]` (port 80)
anymore. Traefik gets the request, finds no IngressRoute that matches the
`web` entrypoint, and returns 404.

Standard fix: add a **Middleware + wildcard IngressRoute** that catches
every HTTP request and 308-redirects it to HTTPS. The repo ships this as
[monitoring/http-to-https-redirect.yaml](../../monitoring/http-to-https-redirect.yaml).

### The YAML

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: cloudkitchen
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  redirectScheme:
    scheme: https
    permanent: true   # 308 Permanent Redirect (cacheable)
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: http-to-https-redirect
  namespace: cloudkitchen
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  entryPoints:
    - web                              # ONLY HTTP — HTTPS routes bypass this
  routes:
    - match: HostRegexp(`.+`)          # match every host (Traefik 3 syntax)
      kind: Rule
      priority: 1                       # lowest priority so any explicit HTTP
                                        # route (e.g. cert-manager's HTTP-01
                                        # challenge) takes precedence
      middlewares:
        - name: redirect-to-https
      services:
        - name: frontend-service        # never actually reached — the
          port: 80                      # middleware short-circuits with 308
```

### Apply

```bash
kubectl apply -f monitoring/http-to-https-redirect.yaml
```

### Verify

```bash
# Each path should now return 308 with Location: https://…
for path in / argocd/ grafana/login prometheus/-/ready alertmanager/-/ready; do
  printf "%-30s -> " "http://...${path}"
  curl -sI "http://vijaygiduthuri.in/${path#/}" \
    | awk '/^HTTP|^[Ll]ocation:/ {printf "%s ", $0}' ; echo
done
# Expect for each:  HTTP/1.1 308 Permanent Redirect  Location: https://vijaygiduthuri.in/...

# And follow the redirect — should land on 200 over HTTPS
for path in / argocd/ grafana/login prometheus/-/ready alertmanager/-/ready; do
  printf "%-30s -> %s\n" "http://...${path}" \
    "$(curl -sIL -o /dev/null -w '%{http_code} %{url_effective}' "http://vijaygiduthuri.in/${path#/}")"
done
# Expect:  200 https://vijaygiduthuri.in/...  for every path
```

### Why this works without breaking Let's Encrypt renewal

cert-manager solves the HTTP-01 challenge by creating a **temporary**
IngressRoute that listens on `web` and matches `/.well-known/acme-challenge/...`.
That route has a more specific path matcher (and a higher implicit priority
than our `priority: 1` catch-all), so Traefik picks it over our redirect
for the challenge traffic only. Everything else still 308s to HTTPS.

> ⚠️ **Why the `traefik` chart's `ports.web.redirectTo` doesn't work for us**
> The Traefik Helm chart used to support `ports.web.redirectTo.port=websecure`
> as a one-line redirect, but the schema in chart v40+ rejects that key
> (`additional properties 'redirectTo' not allowed`). The Middleware +
> IngressRoute pattern above is the chart-version-independent equivalent
> and works on every Traefik 3.x deployment.

---

## 🐛 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Certificate` stuck `READY=False` for >5 min | Let's Encrypt HTTP-01 can't reach `http://vijaygiduthuri.in/.well-known/acme-challenge/…` | Confirm port 80 is open: `curl http://vijaygiduthuri.in/.well-known/acme-challenge/test` should return 404 (not "connection refused"). `kubectl get challenges -A` shows the exact URL Let's Encrypt is probing — curl it from your laptop. |
| Browser shows "NET::ERR_CERT_AUTHORITY_INVALID" or warns | Either the certificate isn't ready yet OR you're hitting Traefik via an IP without the matching `Host:` header (Traefik then serves a self-signed default cert) | Confirm `kubectl -n cloudkitchen get certificate cloudkitchen-tls` shows `READY=True`, and curl with the hostname (`curl https://vijaygiduthuri.in/`), not the IP. |
| Rate-limited by Let's Encrypt (5 certs / week / domain) | You hit issuance failures in a loop or recreated the Certificate multiple times | Wait an hour (the rate window is rolling). Or temporarily point the Issuer's `server:` URL at the staging API (`https://acme-staging-v02.api.letsencrypt.org/directory`) while debugging — staging is unlimited but emits untrusted certs. |
| `kubectl get challenges` shows the challenge stuck "pending" | cert-manager's HTTP-01 solver IngressRoute clashed with something | `kubectl -n cert-manager delete order --all` (forces a fresh attempt). If it keeps failing, check `kubectl -n cert-manager logs deploy/cert-manager` for the specific error. |
| `/grafana` works but the page renders un-styled / blank | TLS secret not present in `monitoring` ns, or the IngressRoute still has `entryPoints: [web]` | Re-run Step 5a (duplicate Secret) + re-verify the edits in 5b landed: `kubectl -n monitoring get ingressroute grafana -o jsonpath='{.spec.entryPoints}'` should print `[websecure]`. |
| `/argocd` returns "ERR_TOO_MANY_REDIRECTS" | ArgoCD's `server.insecure=true` got lost during a chart upgrade — it now tries to redirect from `/argocd` to `https://localhost/argocd` | `helm upgrade argocd argo/argo-cd -n argocd --reuse-values --set 'configs.params.server\.insecure=true' --set 'configs.params.server\.rootpath=/argocd'`, then `kubectl -n argocd rollout restart deploy argocd-server`. |
| Certificate renews but `/grafana` and `/argocd` still serve the OLD cert | The duplicated Secrets in `monitoring` + `argocd` are stale — cert-manager only refreshed `cloudkitchen/cloudkitchen-tls` | Re-run the two `kubectl get | sed | apply` commands from Step 5a. To automate, install [reflector](https://github.com/emberstack/kubernetes-reflector). |
| `error from server: no matches for kind "Certificate"` | cert-manager CRDs didn't install | `kubectl get crd | grep cert-manager.io` should list 6 CRDs. If empty, re-run Step 1 with `--set crds.enabled=true`. |

---

## 📋 Phase 7 cheatsheet

```bash
# 1. cert-manager
kubectl apply -f argocd/apps/app-cert-manager.yaml          # Option A
# OR: helm install cert-manager jetstack/cert-manager -n cert-manager \
#       --create-namespace --set crds.enabled=true --wait

# 2. ClusterIssuer  (one only — letsencrypt-prod)
#    Edit the email: in security/cert-manager/clusterissuer.yaml -> spec.acme.email
kubectl apply -f security/cert-manager/clusterissuer.yaml
kubectl get clusterissuer letsencrypt-prod                  # wait READY=True

# 3. Certificate  (single shot via the prod issuer)
#    Edit commonName + dnsNames in security/cert-manager/certificate.yaml
#    to YOUR domain.
kubectl apply -f security/cert-manager/certificate.yaml
kubectl -n cloudkitchen get cert cloudkitchen-tls -w        # wait READY=True

# 4. Flip the chart to HTTPS
sed -i 's/tls: false/tls: true/' helm/cloudkitchen/values.yaml
sed -i 's/entryPoint: web$/entryPoint: websecure/' helm/cloudkitchen/values.yaml
git add helm/cloudkitchen/values.yaml
git commit -m "phase 7: flip cloudkitchen ingress to HTTPS"
git push origin main
kubectl -n argocd annotate app cloudkitchen argocd.argoproj.io/refresh=hard --overwrite

# 5. Sub-app routes to HTTPS
# 5a — copy the TLS Secret across namespaces
for NS in monitoring argocd; do
  kubectl get secret cloudkitchen-tls -n cloudkitchen -o yaml \
    | sed "s/namespace: cloudkitchen/namespace: ${NS}/" \
    | kubectl apply -f -
done
# 5b — edit monitoring/ingressroutes/*.yaml (web → websecure, add tls: block), apply:
kubectl apply -f monitoring/ingressroutes/
# 5c — re-apply the ArgoCD IngressRoute with websecure + tls (see Step 5c)

# 6. Verify
for URL in / /argocd/ /grafana/login /prometheus/-/ready /alertmanager/-/ready; do
  printf "%-30s  -> " "$URL"
  curl -sIL -o /dev/null -w "HTTP %{http_code}\n" "https://vijaygiduthuri.in$URL"
done
```

---

## 🎉 What you accomplished

- ✅ **cert-manager** running with the Let's Encrypt production issuer
- ✅ A real **browser-trusted TLS certificate** in the cluster, auto-renewing every 75 days
- ✅ Chart flipped to HTTPS via the existing `ingress.tls` toggle — no chart-template edits needed
- ✅ **All 5 UIs** (app, ArgoCD, Grafana, Prometheus, Alertmanager) reachable under the **same domain** over HTTPS

You now have a **production-shape** GKE deployment:

```
https://vijaygiduthuri.in                📱 the app
https://vijaygiduthuri.in/argocd         🚀 GitOps controller
https://vijaygiduthuri.in/grafana        📊 dashboards
https://vijaygiduthuri.in/prometheus     📈 metrics
https://vijaygiduthuri.in/alertmanager   🚨 alerts
```

---

## 🧹 Tearing it all down

When you finish the learning journey:

```bash
# 1. (Optional) helm uninstalls — quick
helm uninstall cloudkitchen   -n cloudkitchen
helm uninstall argocd         -n argocd
helm uninstall traefik        -n traefik
helm uninstall cert-manager   -n cert-manager
# (monitoring + logging Apps will go away with the cluster — they're
#  ArgoCD-managed so you can ALSO `kubectl -n argocd delete app monitoring logging`)

# 2. Delete StatefulSet PVCs (NOT auto-deleted)
kubectl -n cloudkitchen delete pvc -l app=postgres
kubectl -n cloudkitchen delete pvc -l app=nats
kubectl -n monitoring  delete pvc --all
kubectl -n logging     delete pvc --all

# 3. Release the static LB IP (otherwise GCP keeps billing ~$7/month)
gcloud compute addresses delete traefik-lb-ip --region=us-central1

# 4. Destroy the GCP infra
cd gcp-terraform && terraform destroy
```

Billing drops to ~$0/day within ~10 minutes once `terraform destroy` finishes.

---

🏁 **You did it.** The full DevOps lifecycle in seven phases on GKE:
**infra → ingress → CI → CD → DNS → observability → HTTPS**.

Go put this on your resume.
