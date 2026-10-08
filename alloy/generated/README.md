# Generated Alloy Configs

The `.alloy` files in this directory are **read-only snapshots** of the River
configuration that the `grafana/k8s-monitoring` Helm chart generates from
`alloy/povsim-k8s-monitoring-values.yaml`. They are not authored by hand and
should not be edited — any changes here would be blown away the next time
someone dumps a fresh snapshot.

If you want to understand *why* they exist, and how they relate to the values
file that drives them, read `alloy/HELM-VS-RIVER.md` first.

## What each file is

The chart deploys five Alloy pods, each with a different role. Each pod reads
its own ConfigMap. Each file here is a dump of one of those ConfigMaps.

| File | Source ConfigMap | Alloy pod role | Workload shape |
|---|---|---|---|
| `logs.alloy` | `grafana-k8s-monitoring-alloy-logs` | Tails `/var/log/pods/**` and the systemd journal, ships via OTLP | DaemonSet |
| `metrics.alloy` | `grafana-k8s-monitoring-alloy-metrics` | Scrapes kubelet, cAdvisor, kube-state-metrics, node-exporter, application metrics | StatefulSet, clustered for target sharding |
| `profiles.alloy` | `grafana-k8s-monitoring-alloy-profiles` | Runs eBPF profiling and pushes to Pyroscope | DaemonSet, privileged |
| `receiver.alloy` | `grafana-k8s-monitoring-alloy-receiver` | Terminates OTLP (4317/4318) and Zipkin (9411) from application code | Deployment |
| `singleton.alloy` | `grafana-k8s-monitoring-alloy-singleton` | Watches Kubernetes cluster events, ships as logs | Deployment, one replica |

## How they were generated

```bash
mkdir -p alloy/generated
for c in logs metrics profiles receiver singleton; do
  kubectl get configmap -n povsim "grafana-k8s-monitoring-alloy-${c}" \
    -o jsonpath='{.data.config\.alloy}' > "alloy/generated/${c}.alloy"
done
```

Run the same commands to refresh after a `helm upgrade`. The files here are
a snapshot in time and will drift as you edit
`alloy/povsim-k8s-monitoring-values.yaml`.

## Which chart values map to which file

Loose mapping, useful for tracing "I turned on feature X in the values file —
where did it land?"

| Values feature block | Ends up in | Notes |
|---|---|---|
| `clusterMetrics`, `hostMetrics`, `annotationAutodiscovery`, `prometheusOperatorObjects`, `autoInstrumentation` (Beyla) | `metrics.alloy` | Everything on the `alloy-metrics` collector |
| `clusterEvents` | `singleton.alloy` | Needs a single writer to avoid duplicate events |
| `nodeLogs`, `podLogsViaOpenTelemetry` | `logs.alloy` | Filelog + journal sources |
| `applicationObservability` (OTLP receivers) | `receiver.alloy` | External ingress ports 4317/4318/9411 |
| `profiling` (eBPF) | `profiles.alloy` | Requires privileged pod |
| `destinations.grafana-cloud-otlp` | Referenced by `metrics.alloy`, `logs.alloy`, `receiver.alloy`, `singleton.alloy` | Same exporter block appears in every collector that emits OTLP |
| `destinations.grafana-cloud-profiles` | Referenced by `profiles.alloy` only | Pyroscope isn't an OTLP signal |
| `destinations.*.processors.attributes.actions` | Rendered as `otelcol.processor.attributes` inside each OTLP-emitting file | This is where `env=production` gets stamped |

## Running one of these standalone

Each file is valid River — `alloy run <file>.alloy` will accept it. Whether
the resulting pipeline does anything useful depends on how tightly the file
is coupled to the cluster it was generated from.

| File | Runs on a laptop? | Blocker if no |
|---|---|---|
| `receiver.alloy` | ✅ Yes | Just needs `GRAFANA_STACK_ID` + `GRAFANA_CLOUD_TOKEN` env vars; opens ports 4317/4318/9411 |
| `singleton.alloy` | ⚠️ Partial | Reads Kubernetes events via the API server — needs a kubeconfig with cluster access |
| `logs.alloy` | ⚠️ Partial | Tails `/var/log/pods/**` and `/var/log/journal` — only produces output on a Linux Kubernetes node |
| `metrics.alloy` | ❌ No | Scrapes kubelet + kube-state-metrics + node-exporter via cluster networking |
| `profiles.alloy` | ❌ No | eBPF profiling requires `CAP_SYS_ADMIN`, host `/sys` mount, and a Linux kernel with BPF |

For a "just show me Alloy running with River on my laptop" demo, `receiver.alloy`
is the friendliest:

```bash
brew install grafana/grafana/alloy
export GRAFANA_STACK_ID=... GRAFANA_CLOUD_TOKEN=...
alloy run alloy/generated/receiver.alloy
# then in another shell, send OTLP to http://localhost:4318
```

## When to reference these files

- **Understanding what the chart actually produces.** The values file describes
  intent; these files show the mechanism. Useful when you're asked "what does
  Alloy config look like?"
- **Debugging a values-file change.** Diff two snapshots (before and after
  a `helm upgrade`) to see exactly which River components changed.
- **Copy-pasting into `extraConfig`.** If you want to modify a chart-generated
  pipeline, find the relevant block here, tweak it, and drop the result into
  the values file's `extraConfig` field for that feature.
- **Prototyping outside the chart.** Start from `receiver.alloy`, strip what
  you don't need, iterate locally.

## What NOT to use these files for

- **Do not commit changes to them.** They are outputs, not sources.
- **Do not apply them with `kubectl apply` in place of `helm upgrade`.** The
  chart also manages workload manifests, RBAC, ServiceAccounts, sidecar
  services, and Alloy clustering — the River is only ~20% of what the chart
  installs.
- **Do not treat them as authoritative documentation.** They will drift as the
  values file changes. `alloy/povsim-k8s-monitoring-values.yaml` is the
  source of truth.
