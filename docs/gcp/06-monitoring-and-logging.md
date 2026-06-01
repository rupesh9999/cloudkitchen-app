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

## Step 2 — Update `argocd/apps/app-logging.yaml`  *(no edits — already correct)*

The repo already ships [argocd/apps/app-logging.yaml](../../argocd/apps/app-logging.yaml)
configured to install **loki-stack** (Loki + Promtail), with `grafana:
{enabled: false}` (correctly defers Grafana to the monitoring stack).
No changes needed.

---

## Step 3 — Apply both Applications via kubectl

> Filled in when we get there.

---

## Step 4 — Wait for the charts to come up + sanity-check Services

> Filled in when we get there.

---

## Step 5 — Add Traefik IngressRoutes for `/grafana`, `/prometheus`, `/alertmanager`

> Filled in when we get there.

---

## Step 6 — Wire ServiceMonitors so the app pods get scraped

> Filled in when we get there.

---

## Step 7 — Smoke test (Grafana login + a dashboard + a log query)

> Filled in when we get there.

---

## Troubleshooting

(populated from real failures as we hit them)
