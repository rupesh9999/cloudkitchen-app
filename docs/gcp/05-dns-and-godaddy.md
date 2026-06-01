# Phase 5 — DNS + GoDaddy (GCP)

**Goal:** Point your own domain (`vijaygiduthuri.in` in our case) at the
Traefik LoadBalancer IP (`35.224.38.103`), update the chart's IngressRoute
to accept the new hostname, push through the GitOps loop, and verify the
app + ArgoCD UI are reachable by hostname.

**Time:** ~15 min (5 min for the GoDaddy DNS change to propagate + 10 min
for the chart change to flow through CI/ArgoCD).

This is the **GCP counterpart** of [docs/eks/05-traefik-dns-and-godaddy.md](../eks/05-traefik-dns-and-godaddy.md).

| Concern              | EKS                                                            | GKE (this doc)                                                              |
| -------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------- |
| LB endpoint type     | NLB hostname (`a1b2c3.elb.us-east-1.amazonaws.com`) → uses CNAME | TCP LB IPv4 (`35.224.38.103`) → uses **A record**                          |
| Static-IP reservation | NLBs are stable by default; reservation optional               | GKE LB IPs are **ephemeral** by default; reserving as a static IP recommended |
| DNS record type      | `CNAME` (apex needs `ALIAS`/flattening)                        | `A` (works at apex with no special handling)                                |

---

## ✅ Prerequisites

| Need                                                   | How to check                                                                 |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- |
| Phase 4 done (app reachable at `http://<LB_IP>/`)      | `curl -sI http://35.224.38.103/` → `HTTP 200`                                |
| A domain you control                                   | We use **`vijaygiduthuri.in`**, registered at GoDaddy                        |
| `dig` installed locally                                | `dig +short google.com` returns IPs                                          |

---

## What this phase changes

```
                ┌───────────────────────────────┐
                │ GoDaddy DNS for                │
                │   vijaygiduthuri.in            │
                │                                │
                │  A  @  35.224.38.103           │   ← new
                └────────────┬───────────────────┘
                             ▼
              the browser resolves the hostname,
              hits the Traefik LB at 35.224.38.103,
              Traefik matches Host(`vijaygiduthuri.in`)
              in the chart's IngressRoute
                             │
                             ▼
        ┌─────────────────────────────────────────┐
        │ helm/cloudkitchen/values.yaml            │
        │   ingress.hosts:                         │
        │     - vijaygiduthuri.in     ← new        │
        │     - 35.224.38.103         ← kept (IP)  │
        └─────────────────────────────────────────┘
                             │
                             ▼ (committed to main, ArgoCD pulls)
        ┌─────────────────────────────────────────┐
        │ IngressRoute "cloudkitchen" — 10 routes  │
        │ now match either hostname OR the IP      │
        └─────────────────────────────────────────┘
```

---

## Step 1 — Create the A record at GoDaddy

1. Sign into https://account.godaddy.com/products
2. Click your domain → **DNS** (or **Manage DNS**)
3. Click **Add New Record**
4. Fill in:

   | Field        | Value             | Notes                                                                                       |
   | ------------ | ----------------- | ------------------------------------------------------------------------------------------- |
   | **Type**     | `A`               | IPv4 Address record. Don't use `AAAA` (IPv6 only) or `CNAME` (hostname → hostname, not IP). |
   | **Name**     | `@` (apex) or `cloudkitchen`/`app`/etc. (subdomain) | `@` makes the bare `vijaygiduthuri.in` resolve. A label makes `<label>.vijaygiduthuri.in`. |
   | **Value**    | `35.224.38.103`   | Get it from `kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` |
   | **TTL**      | `600` (10 min)    | Keep low during setup so changes propagate fast. Raise to `1 Hour` later.                   |

5. Save.

> 💡 We used **Name = `@`** so requests to the apex `vijaygiduthuri.in`
> resolve. If you'd used `Name = cloudkitchen` instead, the URL becomes
> `cloudkitchen.vijaygiduthuri.in`. Both work; the chart accepts a list of
> hosts (see Step 3).

---

## Step 2 — Wait for DNS propagation + verify

Propagation usually takes 1–10 min for GoDaddy → public resolvers.

```bash
# Resolve against Google's public DNS (faster propagation than your ISP's)
dig +short @8.8.8.8 vijaygiduthuri.in
# Expected: 35.224.38.103

# Quick HTTP check (will 404 until Step 3 lands the chart change — that's expected)
curl -sI -o /dev/null -w "%{http_code}\n" "http://vijaygiduthuri.in/"
```

If `dig` returns nothing or an old IP after 10 min:
- Open https://dnschecker.org and paste your hostname — shows propagation
  across every region; lets you tell "still propagating" apart from "GoDaddy
  config wrong".
- Re-check the GoDaddy DNS page that you actually saved the record.

---

## Step 3 — Parameterize the chart with a list of hosts

The chart's `IngressRoute` template originally had a single
`Host(\`{{ .Values.ingress.domain }}\`)` matcher hard-coded to the LB IP.
That doesn't accept the new hostname. We rewrite it to accept **either**
the hostname or the IP (so curl-by-IP still works for debugging).

### 3a — Update [helm/cloudkitchen/values.yaml](../../helm/cloudkitchen/values.yaml)

Change the `ingress:` block from a single `domain` field to a list of `hosts`:

```yaml
# OLD (single-host, hard-coded):
# ingress:
#   ...
#   domain: 35.224.38.103
#
# NEW (multi-host):
ingress:
  enabled: true
  tls: false
  hosts:
    - vijaygiduthuri.in       # production hostname (matches Host: header for browser requests)
    - 35.224.38.103           # raw LB IP — kept so 'curl http://<IP>/' still works for debugging
  entryPoint: web
  tlsSecretName: cloudkitchen-tls
  clusterIssuer: letsencrypt-prod
```

### 3b — Update [helm/cloudkitchen/templates/ingressroute.yaml](../../helm/cloudkitchen/templates/ingressroute.yaml)

Add a helper at the top of the file that renders the multi-host clause, and
replace every `Host(\`{{ .Values.ingress.domain }}\`)` with a call to it
**wrapped in parentheses** (so `||` between Host()s binds tighter than the
surrounding `&&`).

```yaml
{{- /*
hostsMatcher: renders Traefik's host clause from .Values.ingress.hosts.

Traefik v3's Host() function only accepts ONE hostname argument; the
comma form Host(`a`,`b`) is rejected with
  "Host: unexpected number of parameters; got 2, expected one of [1]"
and the entire IngressRoute gets silently disabled.

The correct multi-host form is one Host() per name, OR'd together:
  Host(`a`) || Host(`b`) || Host(`c`)

We render exactly that, and the caller wraps the expression in parens
so the surrounding `&& PathPrefix(...)` precedence works correctly.
*/ -}}
{{- define "cloudkitchen.hostsMatcher" -}}
{{- range $i, $h := .Values.ingress.hosts -}}{{- if $i }} || {{ end }}Host(`{{ $h }}`){{- end -}}
{{- end -}}
```

Then every route's `match:` line becomes:

```yaml
    - match: ({{ include "cloudkitchen.hostsMatcher" . }}) && PathPrefix(`/api/auth`)
```

For `hosts = [vijaygiduthuri.in, 35.224.38.103]` that renders as:

```
(Host(`vijaygiduthuri.in`) || Host(`35.224.38.103`)) && PathPrefix(`/api/auth`)
```

### 3c — Verify the template renders before pushing

```bash
helm template cloudkitchen ./helm/cloudkitchen \
  | yq '. | select(.kind=="IngressRoute" and .metadata.name=="cloudkitchen") | .spec.routes[].match'
```

You should see 10 lines, each with `(Host(\`vijaygiduthuri.in\`) || Host(\`35.224.38.103\`)) && ...`.

---

## Step 4 — Push through the GitOps loop

```bash
git add helm/cloudkitchen/values.yaml helm/cloudkitchen/templates/ingressroute.yaml
git commit -m "phase 5: support hostname-based access (vijaygiduthuri.in)"
git push origin main
```

**Important:** the workflow `.github/workflows/ci-gcp.yaml` does **not**
trigger on changes to `helm/**` — its `paths:` filter is just the service
directories. So this push **does not** rebuild any images and **does not**
land a `cloudkitchen-ci[bot]` commit. ArgoCD picks the change up directly
from your commit, via its 3-minute repo poll.

To skip the 3-minute wait, force a refresh:

```bash
kubectl -n argocd annotate app cloudkitchen \
  argocd.argoproj.io/refresh=hard --overwrite
```

Watch the Application transition:

```bash
kubectl -n argocd get app cloudkitchen -w
# Expect: Sync Status: OutOfSync -> Synced; Health: Healthy
```

---

## Step 5 — Verify hostname-based access

```bash
# By hostname
curl -sI -o /dev/null -w "/                  -> HTTP %{http_code}\n" "http://vijaygiduthuri.in/"
curl -sI -o /dev/null -w "/argocd/           -> HTTP %{http_code}\n" "http://vijaygiduthuri.in/argocd/"
curl -s    -o /dev/null -w "/api/restaurants   -> HTTP %{http_code}\n" "http://vijaygiduthuri.in/api/restaurants"

# By raw IP (must still work — second host in the list)
curl -sI -o /dev/null -w "/                  -> HTTP %{http_code}\n" "http://35.224.38.103/"
curl -s    -o /dev/null -w "/api/restaurants   -> HTTP %{http_code}\n" "http://35.224.38.103/api/restaurants"
```

All should return **HTTP 200**.

> ⚠️ **HEAD vs GET quirk**: some Gin routes don't define an explicit HEAD
> handler. If `curl -I` (HEAD) returns 404 but `curl` (GET) returns 200,
> that's expected and harmless — Gin treats undeclared HEAD as a separate
> method that wasn't registered. Real browser traffic uses GET, so this
> doesn't affect users.

You should now be able to open these in a browser:
- **App:** http://vijaygiduthuri.in/
- **ArgoCD:** http://vijaygiduthuri.in/argocd/

---

## Step 6 — Verify ArgoCD considers the chart Synced

ArgoCD's auto-sync should have already reconciled, but sanity-check:

```bash
kubectl -n argocd get app cloudkitchen
# NAME           SYNC STATUS   HEALTH STATUS
# cloudkitchen   Synced        Healthy

# Inspect Traefik routers — all 10 'cloudkitchen-*' should be status=enabled, no errors
kubectl -n traefik exec deploy/traefik -- wget -qO- http://localhost:8080/api/http/routers \
  | python3 -c "
import json, sys
ck = [r for r in json.load(sys.stdin) if 'cloudkitchen' in r.get('name','').lower()]
enabled = [r for r in ck if r.get('status')=='enabled']
print(f'  enabled: {len(enabled)} / {len(ck)} routers')
for r in ck:
  if r.get('status') != 'enabled':
    print(f'  BAD: {r[\"name\"]}  err={r.get(\"error\")}')"
# Expect: enabled: 10 / 10 routers
```

---

## Step 7 — (Optional but recommended) Reserve the LB IP as a static address

By default GKE assigns an **ephemeral** IP to the Traefik LoadBalancer. If
you ever delete and recreate the Traefik Service, the IP changes and your
DNS goes stale until you update GoDaddy.

Promote the current IP to a regional static address so it survives Service
recreation:

```bash
PROJECT=project-d31a3358-346c-40e8-bda
REGION=us-central1
LB_IP=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 1. Reserve the current ephemeral IP (this 'upgrades' it to a static)
gcloud compute addresses create traefik-lb-ip \
  --addresses="${LB_IP}" \
  --region="${REGION}" \
  --project="${PROJECT}"

# 2. Pin the Traefik Service to it (helm upgrade — Traefik is still managed
#    by helm, NOT by ArgoCD, since we installed it via helm install in Phase 2)
helm upgrade traefik traefik/traefik \
  --namespace traefik --reuse-values \
  --set service.loadBalancerIP="${LB_IP}"

# 3. Verify nothing changed (rolling restart should not actually swap IPs)
kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
# Same IP as before.
```

If you ever destroy the cluster, **release the static IP** so you don't
get billed for an unused address ($0.01/h ≈ $7/month):

```bash
gcloud compute addresses delete traefik-lb-ip --region=us-central1
```

---

## Troubleshooting

These are the **real failures we hit** on `cloudkitchen-dev-01` while
landing Phase 5, in order:

| Symptom                                                                                                                                       | Root cause                                                                                                                                                                | Fix                                                                                                                                                                                                                            |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `dig vijaygiduthuri.in` returns nothing for 15+ minutes                                                                                       | GoDaddy's authoritative NS hasn't pushed the record yet, OR the record was saved against the wrong domain in your GoDaddy account                                          | https://dnschecker.org distinguishes "propagating" from "not set". Recheck the DNS page; make sure you saved on the right domain.                                                                                              |
| Hostname resolves correctly, but `curl http://<host>/` returns 404 even though `curl http://<LB_IP>/` worked before                            | Chart's IngressRoute has `Host(\`<LB_IP>\`)` hard-coded; the browser/curl sends `Host: <hostname>` and Traefik doesn't match.                                              | Phase 5 Step 3: parameterize the chart with `ingress.hosts: [...]` and rewrite the template to OR them with `||`.                                                                                                              |
| After Step 3 push, ALL routes (including IP-by-curl) return 404; Traefik logs show `error while adding rule Host: unexpected number of parameters; got 2, expected one of [1]` and all `cloudkitchen-*` routers show `status=disabled` in `http://traefik:8080/api/http/routers` | The multi-host syntax `Host(\`a\`,\`b\`)` is invalid in Traefik 3. `Host()` accepts only one argument; multi-host must be written as `Host(\`a\`) || Host(\`b\`)`. | Rewrite the helper to render `||`-joined `Host()` calls + wrap each rule's matcher in `(...)` so `||` binds tighter than the surrounding `&&`. Real example of our fix: commit `f18fb4f`.                                       |
| `curl -I` returns 404 but `curl` (GET) returns 200                                                                                            | Gin doesn't auto-register HEAD handlers for routes defined only as `GET`. Traefik forwards the HEAD verbatim, restaurant-service has no HEAD route, replies 404.          | Not a bug, expected. Real traffic is GET. If you ever need HEAD support, register a `HEAD` handler in the Gin router.                                                                                                          |
| ArgoCD shows `Synced` but the cluster still serves old behaviour                                                                              | The Application reported "Synced" against an old git revision; the new commit hasn't been polled yet.                                                                     | `kubectl -n argocd annotate app cloudkitchen argocd.argoproj.io/refresh=hard --overwrite` — forces an immediate repo refresh + sync. Or just click "Refresh" in the ArgoCD UI.                                                  |
| Chart change works for some routes but not others                                                                                             | One stale rule with the broken syntax was left in the template (sed missed it)                                                                                            | `grep -c 'Host(`{{ .Values.ingress.domain }}`)' helm/cloudkitchen/templates/ingressroute.yaml` — should return 0. If not, replace the leftovers.                                                                                |
| You deleted and recreated the Traefik Service and now DNS resolves to a dead IP                                                              | GKE assigned a new ephemeral IP to the new Service; the old IP is gone.                                                                                                   | Either: update the GoDaddy A record to the new IP, **or** (better) do Step 7 — reserve a static IP so this never happens again.                                                                                                |

---

## What was committed

| Commit    | Files changed                                                  | What it does                                                                                                                  |
| --------- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `5402106` | `helm/cloudkitchen/values.yaml`, `templates/ingressroute.yaml` | First attempt: introduced `ingress.hosts` (list) and the `cloudkitchen.hostsMatcher` helper. Used the comma syntax — broken.   |
| `f18fb4f` | `helm/cloudkitchen/templates/ingressroute.yaml`                | Fixed: replaced `Host(\`a\`,\`b\`)` with `Host(\`a\`) || Host(\`b\`)` and wrapped each call site in parens for precedence.    |

Both commits stay in history on purpose — the bad → good progression is
the same instructive moment a reader following this doc lives through.

---

➡️ **Next:** Phase 6 — Monitoring & Logging (Prometheus + Grafana + Loki).
