# Configuring Alloy: Helm Values vs. River

Grafana Alloy accepts configuration in exactly one format: **River** (an HCL-like
DSL). When you run Alloy on Kubernetes, you have two ways to arrive at that
River:

1. **Write River directly** and mount it into an Alloy pod you deployed yourself.
2. **Write Helm values** and let a chart generate the River, the workloads, RBAC,
   and service topology for you.

This repo uses **path 2**. The rest of this document explains why, what the two
approaches look like side-by-side, and where the files live so you can find each
layer.

## Grafana's official recommendation

Grafana publishes exactly one supported path for running Alloy on Kubernetes:
the Helm chart. From
[`grafana.com/docs/alloy/latest/set-up/install/kubernetes`](https://grafana.com/docs/alloy/latest/set-up/install/kubernetes):

> "Grafana Alloy can be deployed on Kubernetes using its dedicated Helm chart.
> This method provides a streamlined way to manage the deployment and
> configuration of Alloy within a Kubernetes environment."

For cluster-wide observability specifically,
[`grafana.com/docs/alloy/latest/monitor/monitor-kubernetes-logs`](https://grafana.com/docs/alloy/latest/monitor/monitor-kubernetes-logs)
routes readers to the higher-level meta-chart:

> "A Kubernetes Monitoring Helm chart can be used to deploy and monitor
> Kubernetes logs, simplifying configuration and implementing best practices
> for cluster monitoring."

There is no first-party documentation for a "raw River + hand-written manifest"
deployment path. It works — Alloy is just a binary that reads a config file —
but it's not documented as a supported pattern.

## The two Helm charts, and why we picked the meta-chart

Grafana publishes two related charts. They are not equivalent.

| Chart | What it deploys | You supply | Right when… |
|---|---|---|---|
| `grafana/alloy` | One Alloy instance (DaemonSet by default, or StatefulSet / Deployment) | The full River, via `configMap.content` | You already know exactly what River you want to run — one narrow pipeline |
| **`grafana/k8s-monitoring`** ← this repo | Five Alloy instances (metrics, singleton, logs, receiver, profiles) plus kube-state-metrics, node-exporter, kepler, Beyla | Intent ("collect pod logs", "scrape kubelet") via feature toggles; River is generated | You want cluster observability — the standard "collect everything" story |

Both charts wrap River. Neither expects you to hand-write it.

Grafana Cloud's "Add new connection → Kubernetes" onboarding installs
`k8s-monitoring`. That's the path they blog about, publish integration
templates for, and route customers to.

## Why this repo chose Helm (`k8s-monitoring`)

The exercise brief (Stage 2, section 2.1) says "using Grafana Alloy" — it's
runtime-specific, not delivery-specific. Helm was a **deliberate choice** made
here, not something the brief dictated. The rationale:

- **Workload topology is non-trivial.** The five Alloy roles have different pod
  shapes (StatefulSet, DaemonSet, privileged DaemonSet, Deployment, singleton
  Deployment), different RBAC, different mounts, and different privilege
  levels. The chart handles all of it.
- **Sidecar services.** `k8s-monitoring` also deploys kube-state-metrics,
  node-exporter, kepler — each has its own upstream chart if you skip
  `k8s-monitoring`.
- **Fleet Management integration.** `remoteConfig.enabled: true` plumbs OpAMP
  to Grafana Cloud with one line. Doing this by hand means implementing
  OpAMP client wiring.
- **Upgrade path.** `helm upgrade --version "^4"` picks up bug fixes and new
  components. Hand-rolled River means tracking Alloy release notes yourself.

The tradeoff: you configure by **intent** (which signals, which destinations,
which labels), not by **pipeline** (specific River components). If you need
control the chart doesn't expose, each feature accepts an `extraConfig` field
that lets you paste raw River in — best of both worlds.

## The layer cake in this repo

```
┌─────────────────────────────────────────────────────────────────┐
│ alloy/povsim-k8s-monitoring-values.yaml   ← Helm values (YAML)   │
│                                                                  │
│ • Describes intent: enable pod logs, scrape kubelet, etc.       │
│ • References env vars: ${GRAFANA_STACK_ID}, ${GRAFANA_CLOUD_TOKEN}│
│ • This is what you edit.                                         │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼   envsubst + helm upgrade
                           │
┌─────────────────────────────────────────────────────────────────┐
│ Kubernetes ConfigMaps                                            │
│  grafana-k8s-monitoring-alloy-metrics                            │
│  grafana-k8s-monitoring-alloy-singleton                          │
│  grafana-k8s-monitoring-alloy-logs                               │
│  grafana-k8s-monitoring-alloy-receiver                           │
│  grafana-k8s-monitoring-alloy-profiles                           │
│                                                                  │
│ • Each ConfigMap holds a `config.alloy` key with River text.    │
│ • These are the actual Alloy configuration files.               │
│ • Snapshots dumped to alloy/generated/*.alloy for inspection.   │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼   mounted at /etc/alloy/config.alloy
                           │
┌─────────────────────────────────────────────────────────────────┐
│ Five Alloy processes (one per pod, per role)                     │
│                                                                  │
│ • Each process reads its own ConfigMap's River                   │
│ • Fleet Management (OpAMP) can push runtime overrides on top     │
└─────────────────────────────────────────────────────────────────┘
```

The values file is Helm input. The ConfigMap contents are Alloy config. They
are **not the same format** and Alloy cannot read the values file directly.

## How the values file becomes running Alloy

The full apply command from `ORBSTACK.md`:

```bash
set -a && source alloy/.env && set +a && \
  envsubst < alloy/povsim-k8s-monitoring-values.yaml | \
  helm upgrade --install --atomic --timeout 300s grafana-k8s-monitoring grafana/k8s-monitoring \
    --version "^4" --namespace povsim --create-namespace \
    --values -
```

Reading it as a pipeline, left to right:

### 1. Load credentials into the shell — `source alloy/.env`

`alloy/.env` holds `GRAFANA_STACK_ID`, `GRAFANA_CLOUD_TOKEN`, `GRAFANA_METRICS_USERNAME`, etc. The `set -a` flag exports every variable so subprocesses inherit them. Without this step, the next stage has nothing to substitute.

### 2. Interpolate env vars into the values YAML — `envsubst`

Helm does **not** natively substitute shell-style `${VAR}` placeholders. `envsubst` reads `povsim-k8s-monitoring-values.yaml`, replaces every `${GRAFANA_STACK_ID}` / `${GRAFANA_CLOUD_TOKEN}` / etc. with the actual value from the shell env, and streams the substituted YAML to stdout. Nothing is written back to disk — the substituted values live in the pipe only.

Why do it this way instead of `helm --set`? Because `.env` is gitignored and passing secrets on the command line leaks them into shell history and `ps` output. `envsubst` keeps them in-memory.

### 3. Pipe substituted YAML into Helm — `--values -`

The `-` argument tells Helm "read values from stdin." Helm sees the fully-interpolated YAML, no `${...}` placeholders remaining. If you skip `envsubst` and pass the file directly, Helm will happily install the chart with the literal string `${GRAFANA_STACK_ID}` as the username — and the collectors will 401 against Grafana Cloud.

### 4. Helm resolves the chart — `grafana/k8s-monitoring --version "^4"`

`grafana/` is a repo alias set up once with `helm repo add grafana https://grafana.github.io/helm-charts`. Helm looks up the alias, picks the highest 4.x version satisfying `^4` (currently 4.1.6), downloads the chart tarball to a local cache, and unpacks it.

### 5. Helm renders templates

The chart contains ~50 Go template files under `templates/` plus subcharts under `charts/` (one per feature — `feature-cluster-metrics`, `feature-pod-logs-via-opentelemetry`, etc.). Helm:

1. Loads the chart's default `values.yaml`
2. Deep-merges your piped values on top
3. Executes every template file with the merged value tree (Go templates + Sprig)
4. Produces ~30 Kubernetes manifest documents in a single YAML stream:
   - 5 Alloy workloads (StatefulSet, DaemonSet ×2, Deployment ×2)
   - 5 ConfigMaps holding the generated River (one per collector)
   - 5 ServiceAccounts + associated ClusterRoles / ClusterRoleBindings
   - Services (`alloy-receiver` for OTLP/Zipkin ingress, `alloy-metrics` headless for clustering)
   - kube-state-metrics Deployment + Service
   - node-exporter DaemonSet + Service
   - kepler DaemonSet
   - Auth Secrets (`grafana-cloud-otlp-*`, `grafana-cloud-profiles-*`)

### 6. Helm diffs against the current release

The previous state of the release is stored as a Kubernetes Secret named `sh.helm.release.v1.grafana-k8s-monitoring.v<N>` in the `povsim` namespace. Helm compares the newly-rendered manifests to that stored state and computes a three-way diff (previous → desired → current-in-cluster).

### 7. Helm applies via the Kubernetes API

Using your active kubeconfig context (`orbstack` in this repo), Helm creates new objects, patches changed ones, and deletes removed ones. The flags matter:

- `--atomic` — if any step fails or a pod doesn't become Ready before the timeout, roll back to the previous release automatically. Implies `--wait`.
- `--timeout 300s` — cap the whole operation at 5 minutes.
- `--create-namespace` — create `povsim` if it doesn't exist yet.
- `--install` — makes the same command work for both first install and upgrade, so you don't need a separate `helm install` vs `helm upgrade` code path.

### 8. Helm records the new revision

A fresh Secret `sh.helm.release.v1.grafana-k8s-monitoring.v<N+1>` is written recording the new state. This is what `helm history` reads. Each revision keeps the manifests, values, and hooks that were used, so `helm rollback <N>` can restore any past state exactly.

## Inspecting what Helm actually did

| Command | Shows |
|---|---|
| `helm list -n povsim` | Which releases exist and their current revision |
| `helm status grafana-k8s-monitoring -n povsim` | Current state, notes, resource counts |
| `helm history grafana-k8s-monitoring -n povsim` | Every revision, timestamp, and status |
| `helm get values grafana-k8s-monitoring -n povsim` | The values passed in on the last upgrade (with credentials substituted — treat as sensitive) |
| `helm get manifest grafana-k8s-monitoring -n povsim` | Rendered Kubernetes YAML from the last upgrade — the definitive record of what was applied |
| `helm template grafana/k8s-monitoring -f <values>` | Render offline without applying; useful for dry-run and diff review |
| `helm rollback grafana-k8s-monitoring <N> -n povsim` | Roll back to revision N |

If you want to preview a change before applying it, `helm template` + `diff` against the current `helm get manifest` output is the safe workflow.

## What happens on re-apply

Editing `povsim-k8s-monitoring-values.yaml` and re-running the pipeline:

- **ConfigMap changes hot-reload.** Alloy watches its mounted config file and reloads pipelines without restarting the pod. That's why in our session `alloy-metrics`, `alloy-receiver`, `alloy-singleton`, and `alloy-profiles` never restarted when we added `env=production` — the ConfigMap changed, Alloy noticed, live-reloaded.
- **Workload template changes trigger rolling restarts.** Only when the pod spec itself changes (adding a preset, changing an image, altering a volume mount) — e.g., `alloy-logs` rolled when we set `alloy.stabilityLevel: public-preview` because that maps to a container arg.
- **Enabling/disabling a feature can create or destroy entire workloads.** Turning off `profiling` would remove the `alloy-profiles` DaemonSet on next upgrade.
- **Credential changes.** `.env` edits affect `envsubst`-substituted fields — usernames and tokens inside the auth blocks. These land in the auth Secret, and pods reading that Secret restart automatically because Kubernetes reconciles the Secret projection.

Every change is captured as a new Helm revision. `helm history` is your audit log.

## Where each thing lives

| File | Format | Role |
|---|---|---|
| `alloy/povsim-k8s-monitoring-values.yaml` | Helm values (YAML) | The recommended path. Edit this. Consumed by `helm upgrade` |
| `alloy/povsim-k8s-monitoring-values-nonotlp.yaml` | Helm values (YAML) | Alternative variant with separate Prometheus + Loki + OTLP destinations (see `CONFIG.md`) |
| `alloy/config.alloy` | River | **Empty placeholder.** Would hold hand-written River if this repo went fully self-managed. See "When you would write River directly" below |
| `alloy/generated/*.alloy` | River | Snapshots of the ConfigMaps generated by the chart. Read-only reference. See `alloy/generated/README.md` |
| `alloy/CONFIG.md` | Docs | Overview of the runtime layers and how Fleet Management fits in |
| `alloy/HELM-VS-RIVER.md` | Docs | This file |
| `alloy/TELEMETRY-FLOW.md` | Docs | How the sample apps connect to Alloy — app-side instrumentation, the `alloy-receiver` Service contract, and signals that bypass Alloy (Faro, Pyroscope) |
| `helm-charts/pov-sim/values.yaml` + `templates/*.yaml` | Helm chart | The **other** Helm chart in this repo — deploys the sample apps (airlines, flights, frontend). Independent from the `k8s-monitoring` chart but shares the `povsim` namespace so apps can resolve `alloy-receiver` via cluster DNS |
| `airlines/Dockerfile`, `flights/Dockerfile`, `frontend/src/faro.js` | App source | Where OTel/Faro instrumentation is configured — not in Kubernetes manifests |

## When you would write River directly

You would skip the chart and hand-write River in `alloy/config.alloy` (or
similar) only in narrow cases:

- **Single-node / edge deployments** — one VM, one process, one pipeline. No
  Kubernetes, no reason for a chart.
- **A component the chart doesn't expose** — rare. `k8s-monitoring` has ~15
  features covering pretty much every Alloy source/sink. If you find something
  missing, check `extraConfig` first.
- **A minimal demo image** — a "just Alloy" container to show what the config
  language looks like without cluster context.
- **Learning River** — you can hand-write it as a study exercise, then
  translate back to Helm values for real deployments.

For cluster-wide observability on Kubernetes going to Grafana Cloud, none of
those apply. Use the chart.

## The escape hatch: `extraConfig` inside Helm values

When the chart's feature toggles don't cover something specific, every feature
accepts an `extraConfig` field that lets you paste raw River in. Example:

```yaml
podLogsViaOpenTelemetry:
  enabled: true
  extraConfig: |-
    otelcol.processor.transform "custom_tag" {
      log_statements {
        context = "resource"
        statements = [
          `set(attributes["team"], "platform")`,
        ]
      }
      output {
        logs = [otelcol.exporter.otlphttp.grafana_cloud_otlp.input]
      }
    }
```

Same values file, both worlds. This is the answer to "the chart doesn't quite
do what I want" 95% of the time.

## TL;DR

- Grafana recommends the Helm chart for Kubernetes deployments. This repo
  follows that recommendation.
- The file you edit is `alloy/povsim-k8s-monitoring-values.yaml` — that's the
  Helm values, not Alloy config.
- The actual Alloy config (River) is generated by the chart and lives in
  Kubernetes ConfigMaps. Snapshots are dumped to `alloy/generated/*.alloy`
  for reference.
- `alloy/config.alloy` in this repo is empty and unused. It would only be
  populated if this repo abandoned the chart and switched to self-managed
  Alloy, which is not the recommended path.
- If you need a knob the chart doesn't expose, use `extraConfig` on the
  relevant feature — you get chart-managed topology plus River-level control
  where you actually need it.
