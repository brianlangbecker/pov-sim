# Telemetry Flow: How the Apps Connect to Alloy

The Alloy configuration files in this directory describe **the collectors**.
This document describes **the wiring** — how the apps in `airlines/`,
`flights/`, and `frontend/` produce telemetry, how it reaches Alloy, and which
paths intentionally bypass Alloy altogether.

If you only look at the `alloy/` directory you'll see receivers listening on
ports 4317/4318/9411, but no explanation of who's sending. That "who" lives in
two other places: the **app Dockerfiles** and the **pov-sim Helm chart**.

## The two Helm charts in this repo

There are two independent Helm installations. Do not confuse them.

| Helm chart | Purpose | Values file | Namespace |
|---|---|---|---|
| `grafana/k8s-monitoring` | Deploys Alloy + kube-state-metrics + node-exporter + kepler | `alloy/povsim-k8s-monitoring-values.yaml` | `povsim` |
| `./helm-charts/pov-sim` (local) | Deploys the three sample apps (airlines, flights, frontend) | `helm-charts/pov-sim/values.yaml` | `povsim` |

Both install into the same `povsim` namespace so the apps can resolve the
Alloy Service by cluster DNS. There's no ServiceMesh, no ingress between them
— it's just a `ClusterIP` Service that everything in the namespace can hit.

## The Kubernetes Service that ties them together

The `k8s-monitoring` chart's `applicationObservability` feature (enabled in
`alloy/povsim-k8s-monitoring-values.yaml` around line 75) creates this
Service:

```
grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local
  :4317 → OTLP gRPC
  :4318 → OTLP HTTP
  :9411 → Zipkin
```

That DNS name is the **contract**. Apps target it, Alloy answers. If the
receiver preset changes or the release name changes, apps stop shipping
until the DNS name is updated.

## End-to-end map

```
┌─────────────────────────┐    OTLP/gRPC :4317           ┌──────────────────────┐
│ airlines (Java/Spring)  │──────────────────────────────▶│                      │
│                         │                               │                      │
│ Instrumented via:       │                               │                      │
│  OTel Java agent        │                               │                      │
│  (in airlines/Dockerfile)│                              │                      │
└─────────────────────────┘                               │                      │
                                                          │                      │
┌─────────────────────────┐    OTLP/HTTP :4318            │  alloy-receiver      │
│ flights (Python/Flask)  │──────────────────────────────▶│  (Deployment)        │
│                         │                               │                      │
│ Instrumented via:       │                               │  Applies             │
│  opentelemetry-distro   │                               │  env=production      │
│  (in flights/Dockerfile)│                               │  attribute           │
└─────────────────────────┘                               │                      │
                                                          │  Forwards to         │
┌─────────────────────────┐   ─── does NOT go via Alloy ──│  OTLP gateway        │
│ frontend (React)        │                               │                      │
│                         │                               │                      │
│ Instrumented via:       │      Direct HTTP POST         │                      │
│  Faro Web SDK           │───▶ faro-collector-prod-      │                      │
│  (frontend/src/faro.js) │     us-central-7.grafana.net  │                      │
└─────────────────────────┘                               │                      │
                                                          │                      │
                                                          └──────────┬───────────┘
                                                                     │
                                                                     ▼ OTLP/HTTP
                                                    ┌───────────────────────────┐
                                                    │ otlp-gateway-us-central2  │
                                                    │ .grafana.net/otlp         │
                                                    │                           │
                                                    │ (Grafana Cloud)           │
                                                    └───────────────────────────┘
                                                                     │
                                                                     ▼
                                                        Metrics → Mimir
                                                        Logs → Loki
                                                        Traces → Tempo

┌─────────────────────────────────────────────────────────────────────────────┐
│ Also NOT via Alloy: profiling                                                │
│                                                                              │
│ airlines & flights each ship profiles directly to                            │
│   profiles-prod-026.grafana.net:443 (Pyroscope)                              │
│                                                                              │
│ Credentials come from the `grafana-cloud-profiles-grafana-k8s-monitoring`   │
│ Secret that the k8s-monitoring chart creates — so there's a dependency on   │
│ Alloy being installed first, but the runtime path bypasses Alloy.           │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Where each app's instrumentation lives

### airlines (Java / Spring Boot) → Alloy via OTLP gRPC

**File**: `airlines/Dockerfile`

```dockerfile
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar

ENV OTEL_SERVICE_NAME="airlines"
ENV OTEL_RESOURCE_ATTRIBUTES="service.namespace=povsim"
ENV OTEL_EXPORTER_OTLP_ENDPOINT="http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4317"
ENV OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
ENV OTEL_METRICS_EXPORTER="otlp"
ENV OTEL_LOGS_EXPORTER="otlp"
ENV OTEL_TRACES_EXPORTER="otlp"

ENTRYPOINT ["java", "-javaagent:/app/opentelemetry-javaagent.jar", "-javaagent:/app/pyroscope.jar", "-jar", "app.jar"]
```

This is **zero-code instrumentation** — the OTel Java agent injects itself at
JVM startup, discovers Spring Boot / Tomcat / JDBC, and produces
metrics/logs/traces without any code changes in the application. The agent's
sole config is env vars, and every env var it needs is in the Dockerfile.

### flights (Python / Flask) → Alloy via OTLP HTTP

**File**: `flights/Dockerfile`

```dockerfile
RUN pip install --no-cache-dir "opentelemetry-distro[otlp]==$OPENTELEMETRY_DISTRO_VERSION" && \
    opentelemetry-bootstrap -a install

ENV OTEL_SERVICE_NAME="flights"
ENV OTEL_RESOURCE_ATTRIBUTES="service.namespace=povsim"
ENV OTEL_EXPORTER_OTLP_ENDPOINT="http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4318"
ENV OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
ENV OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
ENV OTEL_LOGS_EXPORTER=otlp
ENV OTEL_METRICS_EXPORTER=otlp
ENV OTEL_TRACES_EXPORTER=otlp

CMD ["opentelemetry-instrument", "flask", "run", "--host=0.0.0.0", "--port=5001"]
```

`opentelemetry-distro` provides the SDK plus a wrapper CLI
(`opentelemetry-instrument`) that auto-instruments Flask, requests, and the
Python logging module before handing off to the app. Note: flights sends to
port **4318** (HTTP), airlines sends to port **4317** (gRPC). Both work; the
choice is per-language convention.

### frontend (React) → Faro, bypassing Alloy entirely

**File**: `frontend/src/faro.js`

```javascript
initializeFaro({
  url: 'https://faro-collector-prod-us-central-7.grafana.net/collect/a7ab2622...',
  app: { name: 'pov-sim-frontend', version: '1.0.0' },
  // ...
});
```

The Faro Web SDK posts directly to a Grafana Cloud Faro collector — there is
no Alloy in this path. Faro is designed for browser environments where
requiring a same-cluster collector would defeat the purpose.

Could you route Faro through Alloy? Yes — Alloy has a `faro.receiver`
component and you'd add a receiver on the alloy-receiver pod. Currently
this repo doesn't; it goes direct. That's a legitimate architectural choice
for browser telemetry.

### Profiling (airlines, flights) → Pyroscope, bypassing Alloy

**File**: `helm-charts/pov-sim/templates/airlines-deployment.yaml` and
`flights-deployment.yaml`

```yaml
env:
  - name: PYROSCOPE_APPLICATION_NAME
    value: airlines
  - name: PYROSCOPE_SERVER_ADDRESS
    value: https://profiles-prod-026.grafana.net:443
  - name: PYROSCOPE_BASIC_AUTH_USER
    valueFrom:
      secretKeyRef:
        name: grafana-cloud-profiles-grafana-k8s-monitoring
        key: username
  - name: PYROSCOPE_BASIC_AUTH_PASSWORD
    valueFrom:
      secretKeyRef:
        name: grafana-cloud-profiles-grafana-k8s-monitoring
        key: password
```

Two subtleties worth understanding:

1. **The Pyroscope server address is hard-coded** in the app deployment,
   pointing directly at Grafana Cloud. Profiles bypass Alloy.
2. **The auth Secret is created by the k8s-monitoring chart**, not this
   chart. That's why the ORBSTACK docs insist on installing k8s-monitoring
   *before* pov-sim — otherwise the deployment fails with
   `CreateContainerConfigError: secret not found`.

There's also `profiles.alloy` (the eBPF-based DaemonSet from the
k8s-monitoring chart) that captures profiles at the *host* level. So
profiling has two independent paths:

- App-level (in-process profilers via `-javaagent:pyroscope.jar` and Python
  `pyroscope-python`) — direct to Grafana Cloud
- Host-level (eBPF via `alloy-profiles` DaemonSet) — also direct to Grafana
  Cloud, but from Alloy this time

Both land in the same Pyroscope tenant with different profile types.

## Deployment order

Because the sample-app chart depends on a Secret created by the
k8s-monitoring chart, installation has a required order:

```bash
# 1. Install Alloy first
set -a && source alloy/.env && set +a && \
  envsubst < alloy/povsim-k8s-monitoring-values.yaml | \
  helm upgrade --install grafana-k8s-monitoring grafana/k8s-monitoring \
    --version "^4" --namespace povsim --create-namespace --values -

# 2. Then install the apps
helm upgrade --install pov-sim ./helm-charts/pov-sim --namespace povsim
```

If you reverse the order, airlines and flights fail to start because the
Pyroscope auth Secret doesn't exist yet. See `ORBSTACK.md` for the full
runbook including the app-restart workaround if you already deployed in
the wrong order.

## Summary table

| App | Signal | Path | Instrumentation file | Env / config |
|---|---|---|---|---|
| airlines | Metrics/Logs/Traces | → Alloy `:4317` → OTLP gateway | `airlines/Dockerfile` | `OTEL_*` env |
| airlines | Profiles | → Grafana Cloud Pyroscope (direct) | `helm-charts/pov-sim/templates/airlines-deployment.yaml` | `PYROSCOPE_*` env |
| flights | Metrics/Logs/Traces | → Alloy `:4318` → OTLP gateway | `flights/Dockerfile` | `OTEL_*` env |
| flights | Profiles | → Grafana Cloud Pyroscope (direct) | `helm-charts/pov-sim/templates/flights-deployment.yaml` | `PYROSCOPE_*` env |
| frontend | RUM / Web Vitals | → Grafana Cloud Faro (direct) | `frontend/src/faro.js` | Faro SDK init |
| kubelet / cAdvisor / KSM | Cluster metrics | → Alloy (metrics collector) → OTLP gateway | `alloy/povsim-k8s-monitoring-values.yaml` | `clusterMetrics` block |
| Node journal / pod stdout | Cluster logs | → Alloy (logs collector) → OTLP gateway | `alloy/povsim-k8s-monitoring-values.yaml` | `nodeLogs` + `podLogsViaOpenTelemetry` |
| eBPF host profiles | Profiles | → Alloy (profiles collector) → Pyroscope | `alloy/povsim-k8s-monitoring-values.yaml` | `profiling.ebpf` |

## How to change these connections

- **Change which Alloy the apps target** — edit `OTEL_EXPORTER_OTLP_ENDPOINT`
  in the Dockerfile(s), rebuild the image, redeploy.
- **Add a new signal from a new app** — set `OTEL_*` env vars in that app's
  Dockerfile pointing to `grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local`.
- **Route Faro through Alloy** — add a `faro.receiver` component (via the
  chart's `extraConfig` on `applicationObservability`, or hand-write River).
- **Route Pyroscope through Alloy** — Pyroscope's ingest protocol isn't
  currently one of Alloy's chart-managed receivers, so this would require
  either a Pyroscope-specific Service or leaving the direct path in place.
