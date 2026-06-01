# Phase 6 — Monitoring + Logging (GCP)

**Goal:** Add a full observability stack — **Prometheus** (metrics), **Grafana**
(dashboards), **Alertmanager** (alerts), **Loki** (logs), **Promtail** (log
shipper) — and expose Grafana, Prometheus, and Alertmanager UIs under
sub-paths of your existing domain.

**Time:** ~25 min. Most of it is waiting for the charts to come up
(Prometheus + Alertmanager each provision a PVC and a StatefulSet).

> Before this phase: cluster has the app + ArgoCD + Traefik. No metrics, no logs.
> After:  http://vijaygiduthuri.in/grafana/      — dashboards
>         http://vijaygiduthuri.in/prometheus/   — Prometheus UI
>         http://vijaygiduthuri.in/alertmanager/ — Alertmanager UI
>         Logs from every Pod stream into Loki, queryable from Grafana.

---

## What gets installed

```
                       internet
                          │
                          ▼
              ┌──────────────────────┐
              │ Traefik LB (existing) │
              │ 35.224.38.103         │
              └──────────┬───────────┘
                         │  IngressRoutes (one per UI)
        ┌────────────────┼──────────────────┐
        │                │                  │
        ▼                ▼                  ▼
   /grafana/        /prometheus/      /alertmanager/
        │                │                  │
        ▼                ▼                  ▼
   ┌─────────────────────────────────────────────────────────┐
   │  namespace: monitoring                                   │
   │  ┌──────────┐ ┌────────────┐ ┌────────────┐ ┌──────────┐ │
   │  │ Grafana  │ │ Prometheus │ │Alertmanager│ │node-exp/ │ │
   │  │          │ │   (PVC)    │ │  (PVC)     │ │ kube-st  │ │
   │  └────┬─────┘ └─────┬──────┘ └────────────┘ └──────────┘ │
   │       │             ▲                                    │
   │       │             │ scrape (ServiceMonitor CRDs)       │
   │       │             │                                    │
   │       │       ┌─────┴─────────────────────────────┐      │
   │       │       │ every Pod with /metrics endpoint  │      │
   │       │       └───────────────────────────────────┘      │
   │       │ datasource                                       │
   │       ▼                                                  │
   │  ┌──────────┐                                            │
   │  │   Loki   │ ◀── Promtail (DaemonSet) tails container   │
   │  │  (PVC)   │     logs on every node                     │
   │  └──────────┘                                            │
   │  namespace: logging                                      │
   └─────────────────────────────────────────────────────────┘
```

| Component | Chart | Namespace | Why |
|---|---|---|---|
| Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics | `kube-prometheus-stack` | `monitoring` | The well-known "kube-prom-stack" bundle. One install, all of it wired together with `ServiceMonitor` CRDs. |
| Loki + Promtail | `loki-stack` | `logging` | Loki = log store. Promtail = DaemonSet that tails container logs on every node and ships them to Loki. |

---

## ✅ Prerequisites

| Need                                              | How to check                                                            |
| ------------------------------------------------- | ----------------------------------------------------------------------- |
| Phase 5 done (DNS works, app reachable at hostname) | `curl -sI http://vijaygiduthuri.in/`  → HTTP 200                       |
| Cluster has CPU/memory headroom                   | `kubectl top nodes`  → both nodes < 50% CPU + memory                    |
| Storage class `standard-rwo` available            | `kubectl get storageclass`  → `standard-rwo` should exist (GKE default) |

---

## Step 1 — Update `argocd/apps/app-monitoring.yaml`

The file already exists; we change its `helm.values:` block to make
Grafana / Prometheus / Alertmanager serve at sub-paths on your domain.

**What to do:** open [argocd/apps/app-monitoring.yaml](../../argocd/apps/app-monitoring.yaml)
and replace its `spec.source.helm.values:` block with the version below
(the rest of the file — apiVersion, metadata, destination, syncPolicy —
stays the same).

```yaml
        fullnameOverride: kube-prometheus

        # ---------------------------------------------------------------
        # Grafana — served at /grafana via Traefik IngressRoute (external
        # to this chart). The chart's bundled Ingress is DISABLED.
        # ---------------------------------------------------------------
        grafana:
          enabled: true
          defaultDashboardsEnabled: true
          ingress:
            enabled: false         # 👈 we use a Traefik IngressRoute instead
          grafana.ini:
            server:
              domain: vijaygiduthuri.in
              root_url: "http://vijaygiduthuri.in/grafana/"
              serve_from_sub_path: true
          additionalDataSources:
            - name: Loki           # 👈 auto-add Loki as a Grafana datasource
              type: loki
              uid: loki
              access: proxy
              url: http://loki.logging.svc.cluster.local:3100
              isDefault: false
              jsonData:
                maxLines: 1000
          resources:
            requests: {cpu: 50m,  memory: 128Mi}
            limits:   {cpu: 200m, memory: 256Mi}

        # ---------------------------------------------------------------
        # Prometheus — served at /prometheus.
        # routePrefix + externalUrl together tell Prometheus that all of
        # its UI links + redirects should be /prometheus-prefixed.
        # ---------------------------------------------------------------
        prometheus:
          prometheusSpec:
            retention: 15d
            routePrefix: /prometheus                            # 👈
            externalUrl: http://vijaygiduthuri.in/prometheus    # 👈
            serviceMonitorSelectorNilUsesHelmValues: false
            podMonitorSelectorNilUsesHelmValues: false
            resources:
              requests: {cpu: 250m, memory: 512Mi}
              limits:   {cpu: "1",  memory: 2Gi}
            storageSpec:
              volumeClaimTemplate:
                spec:
                  accessModes: ["ReadWriteOnce"]
                  resources:
                    requests:
                      storage: 20Gi

        # ---------------------------------------------------------------
        # Alertmanager — served at /alertmanager.
        # ---------------------------------------------------------------
        alertmanager:
          enabled: true
          alertmanagerSpec:
            routePrefix: /alertmanager                           # 👈
            externalUrl: http://vijaygiduthuri.in/alertmanager   # 👈
            resources:
              requests: {cpu: 25m,  memory: 64Mi}
              limits:   {cpu: 100m, memory: 128Mi}
```

**What changed compared to the template the repo originally shipped with:**

| Field                                  | Why                                                                                                                                            |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `grafana.ingress.enabled: false`       | We aren't using kube-prom-stack's bundled Ingress — we use a Traefik IngressRoute (added in Step 4) under the existing LB.                     |
| `grafana.grafana.ini.server.*`         | Tells Grafana its public URL is at `/grafana/`. Without this, its HTML asset paths point at `/` and the page breaks behind the sub-path.       |
| `grafana.additionalDataSources: [Loki]` | Wires Loki in as a Grafana datasource so log panels work without manual configuration after install.                                          |
| `prometheus.routePrefix: /prometheus`  | Mounts the Prometheus UI under `/prometheus`. Without it, Prometheus would assume `/` and asset paths break.                                  |
| `prometheus.externalUrl`               | The fully-qualified URL Prometheus emits in alert links + redirects. Must match what Traefik routes to.                                       |
| `alertmanager.routePrefix` + `externalUrl` | Same idea, for Alertmanager.                                                                                                              |
| `ignoreDifferences: StatefulSet.volumeClaimTemplates` | StatefulSet PVC templates are immutable after creation — same trap that hit `cloudkitchen` in Phase 4. Pre-empt it here.        |

> 🔑 **Admin password:** stays at the chart default (`admin / prom-operator`)
> for the first login. We change it via the Grafana UI in Step 5; we don't
> commit a password to git. If you need to rotate without a UI login,
> bump `grafana.adminPassword` in this file later.

---

## Step 2 — Update `argocd/apps/app-logging.yaml`

**File to edit:** [argocd/apps/app-logging.yaml](../../argocd/apps/app-logging.yaml)

The repo already ships this Application configured to install **loki-stack**
(Loki + Promtail) into the `logging` namespace, with `grafana: {enabled: false}`
(correctly defers Grafana to the monitoring stack).

**One thing to add:** an explicit `promtail.config.lokiAddress` override.

The chart's default lokiAddress is `http://<release-name>:3100/...` which
resolves to `http://logging:3100/...`. **But the actual Loki Service is
`logging-loki`** (the chart appends `-loki` to the release name on the Loki
side, NOT on the Promtail side). Without the override, Promtail logs flood
with:

```
dial tcp: lookup logging on 34.118.224.10:53: no such host
```

Add this inside the `promtail:` block:

```yaml
promtail:
  enabled: true
  config:
    lokiAddress: http://logging-loki:3100/loki/api/v1/push
```

That's the only change. Everything else stays.

---

## Step 3 — Apply both Applications

```bash
kubectl apply -f argocd/apps/app-monitoring.yaml
kubectl apply -f argocd/apps/app-logging.yaml
```

ArgoCD picks them up immediately (auto-sync). Watch:

```bash
kubectl -n argocd get app -w
# Wait until both monitoring + logging are Synced + Healthy.
```

**Expected boot timeline** on a 2-node `e2-standard-4` cluster:

| t       | What you should see                                                                |
| ------- | ---------------------------------------------------------------------------------- |
| 0:00    | Apply Applications; ArgoCD starts pulling charts                                   |
| 0:30    | `logging` namespace + Loki PVC + promtail pods created                             |
| 1:00    | `monitoring` namespace + kube-prom-stack CRDs (~30 of them) applied                |
| 1:30    | Prometheus + Alertmanager StatefulSets create PVCs, pods come up                   |
| 2:30    | All 7 monitoring pods Running 1/1                                                  |
| 3:00    | Grafana finishes its first-time setup + datasources load                           |

---

## Step 4 — Sanity-check services + fix the trap GKE always hits

GKE's control plane (etcd, kube-scheduler, kube-controller-manager,
kube-proxy, coredns) is **managed by Google** — none of it is scrape-able
from a worker node. The default kube-prom-stack tries to create Services
for those components anyway, in `kube-system`. Our AppProject
(`argocd/project.yaml`) whitelists only `cloudkitchen`, `monitoring`,
`logging`, `ingress`, `argocd` — so the sync **fails**:

```
namespace kube-system is not permitted in project 'cloudkitchen'
```

The fix is **already** in the manifest we apply in Step 1 — but if you
ever bump kube-prom-stack to a chart version that re-introduces the
defaults, you'll see this again. Disable in `helm.values:`:

```yaml
kubeEtcd:                  {enabled: false}
kubeScheduler:             {enabled: false}
kubeControllerManager:     {enabled: false}
kubeProxy:                 {enabled: false}
coreDns:                   {enabled: false}
```

Verify everything is up:

```bash
kubectl -n monitoring get pods
# alertmanager-kube-prometheus-alertmanager-0     2/2 Running
# kube-prometheus-operator-...                    1/1 Running
# monitoring-grafana-...                          3/3 Running
# monitoring-kube-state-metrics-...               1/1 Running
# monitoring-prometheus-node-exporter-...         1/1 Running   (one per node)
# prometheus-kube-prometheus-prometheus-0         2/2 Running

kubectl -n logging get pods
# logging-loki-0           1/1 Running
# logging-promtail-...     1/1 Running   (one per node)
```

And take note of the actual Service names — you'll need them for Step 5:

```bash
kubectl -n monitoring get svc
# monitoring-grafana                   ClusterIP   ...   80/TCP
# kube-prometheus-prometheus           ClusterIP   ...   9090/TCP
# kube-prometheus-alertmanager         ClusterIP   ...   9093/TCP
```

---

## Step 5 — Add Traefik IngressRoutes for `/grafana`, `/prometheus`, `/alertmanager`

We expose all three UIs under the **existing** Traefik LB (no new IPs, no
new DNS records). The IngressRoute manifests live in the cloudkitchen
helm chart so they ship through the same ArgoCD pipeline as everything else.

### 5a — Add the values to `helm/cloudkitchen/values.yaml`

Append this block (anywhere; the existing `ingress:` block is a natural
neighbor):

```yaml
# Observability — Traefik IngressRoutes that expose Grafana/Prometheus/
# Alertmanager UIs under sub-paths. Service names come from `kubectl -n
# monitoring get svc` (Step 4 above).
observability:
  enabled: true
  grafana:
    servicename: monitoring-grafana
    port: 80
  prometheus:
    servicename: kube-prometheus-prometheus
    port: 9090
  alertmanager:
    servicename: kube-prometheus-alertmanager
    port: 9093
```

### 5b — Add `helm/cloudkitchen/templates/observability-ingressroute.yaml`

```yaml
{{- if .Values.observability.enabled -}}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  entryPoints:
    - {{ .Values.ingress.entryPoint }}
  routes:
    - match: (Host(`{{ .Values.ingress.host }}`) || Host(`{{ .Values.ingress.lbIP }}`)) && PathPrefix(`/grafana`)
      kind: Rule
      services:
        - name: {{ .Values.observability.grafana.servicename }}
          port: {{ .Values.observability.grafana.port }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: prometheus
  namespace: monitoring
spec:
  entryPoints:
    - {{ .Values.ingress.entryPoint }}
  routes:
    - match: (Host(`{{ .Values.ingress.host }}`) || Host(`{{ .Values.ingress.lbIP }}`)) && PathPrefix(`/prometheus`)
      kind: Rule
      services:
        - name: {{ .Values.observability.prometheus.servicename }}
          port: {{ .Values.observability.prometheus.port }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  entryPoints:
    - {{ .Values.ingress.entryPoint }}
  routes:
    - match: (Host(`{{ .Values.ingress.host }}`) || Host(`{{ .Values.ingress.lbIP }}`)) && PathPrefix(`/alertmanager`)
      kind: Rule
      services:
        - name: {{ .Values.observability.alertmanager.servicename }}
          port: {{ .Values.observability.alertmanager.port }}
{{- end }}
```

> 🔑 Same dual-host matcher pattern (`Host(domain) || Host(LB_IP)`) as the
> main IngressRoute — so curl-by-IP for debugging keeps working.

### 5c — Verify access

```bash
curl -sIL -o /dev/null -w "/grafana/      -> HTTP %{http_code}\n" "http://vijaygiduthuri.in/grafana/"
curl -sIL -o /dev/null -w "/prometheus/   -> HTTP %{http_code}\n" "http://vijaygiduthuri.in/prometheus/"
curl -sL "http://vijaygiduthuri.in/alertmanager/-/ready"   # prints "OK"
```

Open in browser:
- **Grafana:** http://vijaygiduthuri.in/grafana/  — login `admin / prom-operator`
- **Prometheus:** http://vijaygiduthuri.in/prometheus/
- **Alertmanager:** http://vijaygiduthuri.in/alertmanager/

> ⚠️ The default Grafana password is `prom-operator`. **Change it on first
> login** (User Icon → Profile → Change Password) and then optionally
> delete the chart's `admin-user`/`admin-password` Secret.

---

## Step 6 — Wire ServiceMonitors so Prometheus scrapes our 8 backend services

The `kube-prom-stack` Prometheus auto-discovers `ServiceMonitor` CRDs in
**every namespace** (we set `serviceMonitorSelectorNilUsesHelmValues: false`
in Step 1). So we just drop one ServiceMonitor in the cloudkitchen ns and
Prometheus picks it up.

All 8 backend services already share the label `app.kubernetes.io/part-of:
cloudkitchen` (rendered by the chart's `<svc>-service.yaml` templates) and
expose `/metrics` on the `http` port. One ServiceMonitor selects all of
them at once.

### Add `helm/cloudkitchen/templates/servicemonitor.yaml`

```yaml
{{- if .Values.observability.enabled -}}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cloudkitchen-services
  namespace: {{ .Values.namespace }}
  labels:
    release: kube-prometheus           # match kube-prom-stack's default selector
spec:
  namespaceSelector:
    matchNames:
      - {{ .Values.namespace }}
  selector:
    matchLabels:
      app.kubernetes.io/part-of: cloudkitchen
  endpoints:
    - port: http                       # the Service port name (NOT the number)
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
{{- end }}
```

### Verify scrape

```bash
curl -s "http://vijaygiduthuri.in/prometheus/api/v1/query?query=up%7Bnamespace%3D%22cloudkitchen%22%7D" \
  | python3 -m json.tool | head -40
```

Each of the 8 services should show `up = 1`. Confirm with a real query:

```bash
curl -s "http://vijaygiduthuri.in/prometheus/api/v1/query?query=sum%20by(service)%20(http_requests_total%7Bnamespace%3D%22cloudkitchen%22%7D)" \
  | python3 -m json.tool
```

Each service should report ~hundreds–thousands of `http_requests_total`
(those are mostly health/readiness probe hits accumulating over time).

---

## Step 7 — Smoke test in Grafana

1. Open **http://vijaygiduthuri.in/grafana/** and log in.
2. Top-left menu → **Connections → Data sources**:
   - **Prometheus** should be there (added by the chart automatically).
   - **Loki** should be there too (we added it via `additionalDataSources`
     in Step 1).
   - Click each and "Save & test" — both should turn green.
3. Top-left menu → **Dashboards → Browse**. Pick **"Kubernetes / Compute Resources / Namespace (Pods)"**:
   - Select Namespace = `cloudkitchen` in the top dropdown.
   - You should see CPU + memory usage panels for each of the 12 cloudkitchen pods.
4. Top-left menu → **Explore**. Switch the datasource to **Loki**:
   - Try query  `{namespace="cloudkitchen"}`  + Run.
   - You should see live logs streaming from every cloudkitchen pod.

If all three of those work, **Phase 6 is done.**

---

## Troubleshooting

These are the real failures we hit on `cloudkitchen-dev-01` while landing
Phase 6, in order:

| Symptom                                                                                            | Cause                                                                                                                            | Fix                                                                                                                                                              |
| -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ArgoCD `monitoring` App stuck `OutOfSync / Missing`, retry messages say `namespace kube-system is not permitted in project` | kube-prom-stack tried to create scrape Services in `kube-system` for GKE-managed components.                                     | In `app-monitoring.yaml` set `kubeEtcd/kubeScheduler/kubeControllerManager/kubeProxy/coreDns: {enabled: false}`. They're unscrape-able on GKE anyway.            |
| `app-monitoring.yaml` edited but the live App's `helm.values:` still shows the old block            | `kubectl apply` ran against a partially-formed ArgoCD operation in retry state.                                                  | Clear the stuck operation, then re-apply: `kubectl -n argocd patch app monitoring --type merge -p '{"operation":null}'` then `kubectl apply -f .../app-monitoring.yaml` again. |
| Grafana datasource for Loki shows "Cannot connect"                                                  | URL `http://loki.logging.svc.cluster.local:3100` is wrong — the Service is `logging-loki`, not `loki`. The loki-stack chart adds the `-loki` suffix on the Loki Service. | Fix the Grafana datasource URL to `http://logging-loki.logging.svc.cluster.local:3100`. (We do this in Step 1.)                                                  |
| Promtail logs flood with `dial tcp: lookup logging on ...:53: no such host`                         | Same naming surprise as above. The chart's default `promtail.config.lokiAddress` is `http://<release>:3100/...`, which resolves to `http://logging:3100` — broken. | Override `promtail.config.lokiAddress: http://logging-loki:3100/loki/api/v1/push` in `app-logging.yaml`. (Step 2.)                                              |
| After changing `promtail.config.lokiAddress`, Promtail pods don't pick it up                        | The promtail config is stored in a **Secret** (not a ConfigMap); pods don't auto-restart on Secret change.                        | `kubectl -n logging rollout restart daemonset logging-promtail` after the new Secret is in place.                                                                |
| Prometheus + Alertmanager UIs return 404 even though `/grafana/` works                              | Both have `routePrefix` config that affects how they generate redirects. If `routePrefix` doesn't match the IngressRoute path, links break. | `app-monitoring.yaml` sets `prometheus.prometheusSpec.routePrefix: /prometheus` and `alertmanager.alertmanagerSpec.routePrefix: /alertmanager` (Step 1).         |
| `curl -I` (HEAD) returns 405 on Prometheus/Alertmanager UIs                                         | Those servers don't define HEAD. Same Gin-style quirk.                                                                            | Use GET (`curl` without `-I`). Real browser traffic uses GET.                                                                                                    |
| StatefulSets (Prometheus / Alertmanager / Loki) show permanent OutOfSync on `volumeClaimTemplates`  | StatefulSet PVC templates are **immutable** after creation — same trap that bit the cloudkitchen App.                            | Add `ignoreDifferences: [{group: apps, kind: StatefulSet, jsonPointers: [/spec/volumeClaimTemplates]}]` on the Application. (`app-monitoring.yaml` already does.) |

---

➡️ **Next:** Phase 7 — HTTPS via cert-manager + Let's Encrypt (flip the
chart from HTTP entryPoint `web` to TLS-terminated `websecure`).
