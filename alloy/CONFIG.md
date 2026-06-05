# Alloy Configuration — What Actually Runs

This directory contains three files related to Alloy. Only one of them holds
deployment configuration; the other two are either empty or a credentials stub.
The **real** pipeline config that the running Alloy collectors execute lives in
**Grafana Cloud Fleet Management**, not in this repo.

## The files in this directory

| File | Purpose | Used when? |
|---|---|---|
| `povsim-k8s-monitoring-values.yaml` | Helm values for the `k8s-monitoring` chart | At `helm install` / `helm upgrade` |
| `config.alloy` | Local Alloy pipeline config (River syntax) | **Empty — not used** |
| `.env` / `.env.example` | Env vars consumed by `envsubst` before Helm install | At install time |

## Configuration layers (in order of precedence at runtime)

```
┌────────────────────────────────────────────────────────────┐
│ 1. Helm chart values (povsim-k8s-monitoring-values.yaml)    │
│    → defines WHICH collectors get deployed and their PRESETS│
│    → sets destinations (Prometheus, Loki, OTLP, Pyroscope)  │
│    → enables Fleet Management remoteConfig                  │
└────────────────────────────────────────────────────────────┘
                              │
                              ▼ (collector pod starts)
┌────────────────────────────────────────────────────────────┐
│ 2. Helm-generated baseline River config                     │
│    → the k8s-monitoring chart auto-generates River pipelines│
│      for each enabled feature (clusterMetrics, nodeLogs,    │
│      applicationObservability, etc.)                        │
│    → stored in a ConfigMap mounted into each Alloy pod      │
└────────────────────────────────────────────────────────────┘
                              │
                              ▼ (collector calls home)
┌────────────────────────────────────────────────────────────┐
│ 3. Fleet Management remote config (OpAMP)                   │
│    URL: https://fleet-management-prod-002.grafana.net       │
│    → overrides / extends the baseline at runtime            │
│    → managed in the Grafana Cloud UI, not in git            │
└────────────────────────────────────────────────────────────┘
```

`config.alloy` in this repo is **empty** and is **not loaded** — it's a leftover
placeholder. Alloy gets its configuration entirely from layers 2 and 3.

## What `povsim-k8s-monitoring-values.yaml` actually configures

### Destinations (where telemetry is shipped)

| Destination | Type | URL |
|---|---|---|
| `grafana-cloud-metrics` | prometheus | `prometheus-us-central2.grafana.net/api/prom/push` |
| `grafana-cloud-logs` | loki | `logs-prod-037.grafana.net/loki/api/v1/push` |
| `gc-otlp-endpoint` | otlp (http) | `otlp-gateway-us-central2.grafana.net/otlp` |
| `grafana-cloud-profiles` | pyroscope | `profiles-prod-026.grafana.net:443` |

Credentials come from `.env` via `envsubst` (see `ORBSTACK.md`):
`GRAFANA_METRICS_USERNAME`, `GRAFANA_LOGS_USERNAME`, `GRAFANA_STACK_ID`,
`GRAFANA_CLOUD_TOKEN`.

### Collectors (Alloy pods deployed)

| Collector | Preset | Role |
|---|---|---|
| `alloy-metrics` | clustered, statefulset | Scrapes Prom metrics, host/cluster/cost metrics, autoinstrumentation |
| `alloy-singleton` | singleton | Cluster events (one replica only) |
| `alloy-logs` | filesystem-log-reader, daemonset | Tails node and pod logs |
| `alloy-receiver` | deployment | OTLP/Zipkin ingress (4317, 4318, 9411) |
| `alloy-profiles` | privileged, daemonset | eBPF profiling (Pyroscope) |

### Features enabled

- `clusterMetrics`, `hostMetrics` (linux + windows + energy), `costMetrics`
- `clusterEvents`, `nodeLogs`, `podLogsViaLoki`
- `applicationObservability` — OTLP gRPC/HTTP + Zipkin receivers
- `autoInstrumentation` with Beyla (traces NOT forwarded to app o11y)
- `profiling`
- `annotationAutodiscovery`, `prometheusOperatorObjects`

### Sidecar telemetry services

- `kube-state-metrics`, `node-exporter`, `windows-exporter`
- `opencost` (cluster ID: `orbstack`, sources metrics from `grafana-cloud-metrics`)
- `kepler` (energy metrics)

### Fleet Management (the key part)

```yaml
collectorCommon:
  alloy:
    remoteConfig:
      enabled: true
      url: https://fleet-management-prod-002.grafana.net
```

With `remoteConfig.enabled: true`, every Alloy pod connects to Fleet
Management over OpAMP and pulls additional/override pipeline configuration
from Grafana Cloud. Any pipeline tweaks made there apply without re-running
Helm.

## Why does `config.alloy` being empty still "work"?

Because nothing reads it. The Helm chart generates its own River config from
the values file and mounts it as a ConfigMap; Fleet Management layers more
on top at runtime. The `config.alloy` file is not referenced by the chart.

If you wanted to **fully self-manage** Alloy (no Helm chart, no Fleet
Management), you would:

1. Set `collectorCommon.alloy.remoteConfig.enabled: false`
2. Write the full pipeline (sources, processors, exporters) into `config.alloy`
3. Mount it into the Alloy pod and point Alloy at it with `--config.file`

That's not how this repo is set up.

## How to inspect the live config

```bash
# See which collector pods are running
kubectl get pods -n povsim | grep alloy

# Dump the merged config from a running pod's UI
kubectl port-forward -n povsim deploy/grafana-k8s-monitoring-alloy-receiver 12345:12345
# then open http://localhost:12345/graph to view the active River pipeline

# View the Helm-generated ConfigMap
kubectl get configmap -n povsim -l app.kubernetes.io/name=alloy -o yaml
```

## TL;DR

- `povsim-k8s-monitoring-values.yaml` → tells Helm what to install and where
  to ship data.
- `config.alloy` → **empty placeholder, not loaded**.
- Real pipeline behavior → generated by the Helm chart + overridden by
  Grafana Cloud Fleet Management at runtime.
