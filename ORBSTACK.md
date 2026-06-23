# 🚀 PoV Flight Simulator — OrbStack + Helm 🚀

Welcome to the PoV Flight Simulator (OrbStack + Helm edition)

- [About](#about)
- [Getting Up and Running](#getting-up-and-running)
  - [Prerequisites](#prerequisites)
  - [Step 1 — Install Grafana k8s Monitoring (Alloy)](#step-1--install-grafana-k8s-monitoring-alloy)
  - [Step 2 — Build the app images](#step-2--build-the-app-images)
  - [Step 3 — Deploy pov-sim](#step-3--deploy-pov-sim)
  - [Step 4 — (OrbStack only) Deploy standalone cAdvisor](#step-4--orbstack-only-deploy-standalone-cadvisor)
  - [Step 5 — Verify the website is running](#step-5--verify-the-website-is-running)
- [Simulate traffic to the services](#simulate-traffic-to-the-services)
  - [airlines-loadgen](#running-airlines-loadgen)
  - [flights-loadgen](#running-flights-loadgen)
  - [frontend-loadgen](#running-frontend-loadgen)
- [Appendix — Full Uninstall / Clean Slate](#appendix--full-uninstall--clean-slate)
  - [A1 — Uninstall the apps (pov-sim)](#a1--uninstall-the-apps-pov-sim)
  - [A2 — Remove standalone cAdvisor](#a2--remove-standalone-cadvisor-orbstack-only)
  - [A3 — Uninstall Grafana k8s Monitoring (Alloy)](#a3--uninstall-grafana-k8s-monitoring-alloy)
  - [A4 — Delete the namespace](#a4--delete-the-namespace)
  - [A5 — Clean up cluster-scoped orphans](#a5--clean-up-cluster-scoped-orphans)
  - [A6 — Force-terminate a stuck namespace](#a6--force-terminate-a-stuck-namespace)
  - [A7 — Verify everything is gone](#a7--verify-everything-is-gone)
  - [A8 — One-shot uninstall script](#a8--one-shot-uninstall-script-advanced)

> **Install order matters.** The pov-sim deployments reference a Pyroscope
> auth Secret (`grafana-cloud-profiles-grafana-k8s-monitoring`) that is
> created by the Grafana k8s-monitoring chart. **Install k8s-monitoring
> before pov-sim** or the app pods will fail with `CreateContainerConfigError: secret "grafana-cloud-profiles-grafana-k8s-monitoring" not found`.
> See [PROFILES.md](./PROFILES.md) for the full profiling setup.

# About

This application comprises the following services:

| Name | Description | Tech | Quick Link |
| :---: | :---: | :---: | :---: |
| `airlines` | Backend service | Java Spring Boot app | http://airlines.povsim.svc.cluster.local:8080/swagger-ui/index.html#/ |
| `flights` | Backend service | Python Flask app | http://flights.povsim.svc.cluster.local:5001/apidocs/ |
| `frontend` | Frontend service | React app | http://frontend.povsim.svc.cluster.local:3000/ |
|||

The `frontend` service is a simple React app that makes API requests to both the `airlines` and `flights` services.
![alt text](resources/povsim.png)

# Getting Up and Running

## Prerequisites

- Install [OrbStack](https://orbstack.dev/) on your local machine
- Install [Helm](https://helm.sh/docs/intro/install/) on your local machine
- Clone this repo to your local machine
```
git clone https://github.com/aninamu/pov-sim.git
```

## Step 1 — Install Grafana k8s Monitoring (Alloy)

**Do this first.** It creates the `povsim` namespace (via
`--create-namespace`) and the
`grafana-cloud-profiles-grafana-k8s-monitoring` Secret that the app
deployments need for Pyroscope basic-auth credentials. The pov-sim
chart deliberately does *not* create the namespace itself — Step 1 owns
it, and Helm will refuse to adopt a namespace it didn't create.

This repo includes a pre-configured values file for the [Grafana k8s Monitoring](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/) Helm chart that ships telemetry (metrics, logs, traces, profiles) to Grafana Cloud.

Two variants are available — pick one:

| File | What it does | When to use |
| --- | --- | --- |
| `alloy/povsim-k8s-monitoring-values.yaml` (default) | All signals via the single OTLP gateway (`otlp-gateway-us-central2.grafana.net/otlp`), profiles direct to Pyroscope. opencost + windows-exporter disabled. | You want the simplest setup, a single OTLP-write token, and don't need cost metrics. |
| `alloy/povsim-k8s-monitoring-values-nonotlp.yaml` | Separate Prometheus and Loki destinations + OTLP for traces + Pyroscope for profiles. Includes opencost (needs Prometheus reads) and the Windows exporter. | You want cost metrics, a Windows node, or you're matching a pre-existing non-OTLP setup. |

The install commands below show the default (OTLP) file. To use the
non-OTLP backup, swap the filename in the `envsubst <` line.

Install `gettext` if you don't have it (provides `envsubst`):
```
brew install gettext
```

Add the Grafana Helm repo if you haven't already:
```
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
```

Copy `alloy/.env.example` to `alloy/.env` and fill in your credentials:
```
cp alloy/.env.example alloy/.env
```

Install using the values file in `alloy/`, with credentials sourced from `alloy/.env`:
```
set -a && source alloy/.env && set +a && \
  envsubst < alloy/povsim-k8s-monitoring-values.yaml | \
  helm upgrade --install --atomic --timeout 300s grafana-k8s-monitoring grafana/k8s-monitoring \
  --version "^4" --namespace "povsim" --create-namespace \
  --values -
```

Confirm the collectors are running and the Pyroscope secret exists:
```
kubectl get pods   -n povsim | grep alloy
kubectl get secret -n povsim grafana-cloud-profiles-grafana-k8s-monitoring
```

Both must succeed before moving on. The app pods reference that secret
by name and will crash-loop until it exists.

Once installed, the apps send telemetry to these endpoints (already
wired into the airlines, flights, and chart templates):

| Protocol | Endpoint |
| :---: | :---: |
| OTLP gRPC | `http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4317` |
| OTLP HTTP | `http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4318` |
| Zipkin | `http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:9411` |

## Step 2 — Build the app images

From the project root:
```
docker build -t pov-sim-airlines:latest ./airlines
docker build -t pov-sim-flights:latest ./flights
docker build \
  --build-arg REACT_APP_AIRLINES_API_URL=http://airlines.povsim.svc.cluster.local:8080/airlines \
  --build-arg REACT_APP_FLIGHTS_API_URL=http://flights.povsim.svc.cluster.local:5001/flights \
  -t pov-sim-frontend:latest ./frontend
```

> **Faro RUM:** the frontend ships browser telemetry (errors, web vitals,
> sessions, route changes, traces) to Grafana Cloud Frontend
> Observability via the Faro Web SDK initialized in
> `frontend/src/faro.js`. To verify, open the app and check
> DevTools → Network for POST requests to `faro-collector-…grafana.net`.

OrbStack shares its Docker daemon with the in-cluster kubelet, so the
images are immediately available to k8s with `imagePullPolicy: Never`
(set in `values.yaml`).

## Step 3 — Deploy pov-sim

```
helm upgrade --install pov-sim ./helm-charts/pov-sim --namespace povsim
```

- *The `airlines` service runs on http://airlines.povsim.svc.cluster.local:8080/ with Swagger doc UI at http://airlines.povsim.svc.cluster.local:8080/swagger-ui/index.html#/*
- *The `flights` service runs on http://flights.povsim.svc.cluster.local:5001/ with Swagger doc UI at http://flights.povsim.svc.cluster.local:5001/apidocs/*
- *The `frontend` service runs on http://frontend.povsim.svc.cluster.local:3000/*

Confirm all pods are running:
```
kubectl get pods -n povsim
```

If a pod shows `CreateContainerConfigError` referencing
`grafana-cloud-profiles-grafana-k8s-monitoring`, you skipped Step 1 —
go back, install k8s-monitoring, then either wait for the kubelet to
retry or force a restart:
```
kubectl rollout restart deploy/airlines deploy/flights -n povsim
```

Tear down with:
```
helm uninstall pov-sim -n povsim
```

## Step 4 — (OrbStack only) Deploy standalone cAdvisor

OrbStack's kubelet does **not** expose `container_*` metrics, so on
OrbStack we run a standalone cAdvisor DaemonSet and let Alloy's
annotation autodiscovery pick it up. On a normal cluster, skip this.

```
kubectl apply -f cadvisor/cadvisor-daemonset.yaml
kubectl get pods -n povsim -l app.kubernetes.io/name=cadvisor
```

## Step 5 — Verify the website is running

Before driving load or opening Grafana, make sure the three services
actually respond. OrbStack publishes every in-cluster Service at
`<svc>.<ns>.svc.cluster.local` so you can hit them directly from your
laptop's browser — no port-forward needed.

**Quick check from the terminal:**
```
curl -sS -o /dev/null -w "frontend: %{http_code}\n" http://frontend.povsim.svc.cluster.local:3000/
curl -sS -o /dev/null -w "airlines: %{http_code}\n" http://airlines.povsim.svc.cluster.local:8080/airlines
curl -sS -o /dev/null -w "flights:  %{http_code}\n" http://flights.povsim.svc.cluster.local:5001/
```

All three should return `200`. If any returns connection-refused, the
corresponding pod isn't ready yet — `kubectl get pods -n povsim` and
wait for `1/1 Running`.

**Open in a browser:**

| Service | URL |
| --- | --- |
| Frontend (React UI) | http://frontend.povsim.svc.cluster.local:3000/ |
| Airlines Swagger    | http://airlines.povsim.svc.cluster.local:8080/swagger-ui/index.html |
| Flights  Swagger    | http://flights.povsim.svc.cluster.local:5001/apidocs/ |

Click around the frontend and you should see flight/airline data
populating — that confirms frontend → airlines → flights is wired up
end-to-end.

**If browser access doesn't work** (rare on OrbStack, common on other
local clusters), fall back to `kubectl port-forward`:
```
kubectl port-forward -n povsim svc/frontend 3000:3000
# then open http://localhost:3000/ in another tab
```

**Common failure modes:**

| Symptom | Likely cause |
| --- | --- |
| `Connection refused` on the frontend | Pod is still `ContainerCreating` — wait, then retry. |
| `CreateContainerConfigError` referencing `grafana-cloud-profiles-grafana-k8s-monitoring` | You skipped [Step 1](#step-1--install-grafana-k8s-monitoring-alloy). Install k8s-monitoring, then `kubectl rollout restart deploy/airlines deploy/flights -n povsim`. |
| Frontend loads but shows no data / CORS errors in browser console | The airlines `AirlinesController` CORS allowlist is hardcoded to `*.povsim.svc.cluster.local`. If you're hitting a different hostname (e.g. via ingress or port-forward to `localhost`), it'll block — use the cluster-DNS URLs above. |
| Pod stuck `ImagePullBackOff` on `pov-sim-*:latest` | You skipped [Step 2](#step-2--build-the-app-images), or built images outside OrbStack's Docker daemon. Re-run the `docker build` commands from a shell where `docker context show` returns `orbstack`. |

# Simulate traffic to the services

The `scripts/` directory includes load generator scripts you can use to make batch sets of requests to your running services.

- The `airlines-loadgen.sh` script generates load to the `airlines` service
- The `flights-loadgen.sh` script generates load to the `flights` service
- The `frontend-loadgen.sh` script drives a headless browser against the
  `frontend` service so Faro RUM events fire and frontend → airlines →
  flights traces are produced end-to-end

## Running airlines-loadgen

*Note: You may need to run the following command to add the proper permissions to execute the script*
```
chmod +x airlines-loadgen.sh
```

The `airlines-loadgen` script makes API requests to the `airlines` service. You can optionally specify the following parameters to the script:
- A target `-t` to set the environment: `local` or `orbstack` (default = `local`)
- An error rate `-e` to force the requests to the service to error out at that rate
- A duration `-d` to specify the number of seconds the script should run
- A base URL `-b` to override the target URL entirely

From the `scripts/` directory:

- Run the script targeting OrbStack
  ```
  ./airlines-loadgen.sh -t orbstack
  ```

- View usage
  ```
  ./airlines-loadgen.sh -h
  ```

- Example: Run the script for 120 seconds generating a 25% error rate targeting OrbStack
  ```
  ./airlines-loadgen.sh -t orbstack -e 0.25 -d 120
  ```

## Running flights-loadgen

*Note: You may need to run the following command to add the proper permissions to execute the script*
```
chmod +x flights-loadgen.sh
```

The `flights-loadgen` script makes API requests to the `flights` service. You can optionally specify the following parameters to the script:
- A target `-t` to set the environment: `local` or `orbstack` (default = `local`)
- An error rate `-e` to force the requests to the service to error out at that rate
- A duration `-d` to specify the number of seconds the script should run
- A base URL `-b` to override the target URL entirely

From the `scripts/` directory:

- Run the script targeting OrbStack
  ```
  ./flights-loadgen.sh -t orbstack
  ```

- View usage
  ```
  ./flights-loadgen.sh -h
  ```

- Example: Run the script for 120 seconds generating a 25% error rate targeting OrbStack
  ```
  ./flights-loadgen.sh -t orbstack -e 0.25 -d 120
  ```

## Running frontend-loadgen

*Note: You may need to run the following command to add the proper permissions to execute the script*
```
chmod +x frontend-loadgen.sh
```

The `frontend-loadgen` script uses [k6](https://k6.io/docs/) with the
`k6/browser` module to drive a real headless Chromium against the
`frontend` service. This is the **only** loadgen that exercises the
React bundle in a real browser — which means it's the only one that
produces Faro RUM events (errors, web vitals, route changes, sessions)
and stitched frontend → airlines → flights traces in Tempo.

**Prerequisite:** install k6 v0.46+ (the browser module ships built-in).

```
brew install k6
```

You can optionally specify the following parameters to the script:
- A target `-t` to set the environment: `local` or `orbstack` (default = `local`)
- A VUs count `-v` for the number of parallel browsers (default = `2`)
- A duration `-d` in seconds (default = `60`)

From the `scripts/` directory:

- Run the script targeting OrbStack
  ```
  ./frontend-loadgen.sh -t orbstack
  ```

- View usage
  ```
  ./frontend-loadgen.sh -h
  ```

- Example: 4 parallel browsers for 5 minutes (300 sec) against OrbStack
  ```
  ./frontend-loadgen.sh -t orbstack -v 4 -d 300
  ```

The `local` target points at `http://localhost:3000` (use this when
you're running `kubectl port-forward svc/frontend 3000:3000` or
`npm start` from `./frontend`). The `orbstack` target points at
`http://frontend.povsim.svc.cluster.local:3000` and relies on OrbStack
exposing cluster DNS to the host.

## Running all three loadgens together (10 minutes)

From the `scripts/` directory, run all three loadgens in parallel for 10
minutes (600 seconds) against the OrbStack deployment. Backend
loadgens drive Tempo trace volume at a 25% error rate; the browser
loadgen runs 2 parallel headless browsers to produce Faro RUM events
and the frontend-rooted traces:

```
./airlines-loadgen.sh -t orbstack -e 0.25 -d 600 & \
./flights-loadgen.sh  -t orbstack -e 0.25 -d 600 & \
./frontend-loadgen.sh -t orbstack -v 2 -d 600    & \
wait
```

Tweak the backend rate by changing `-e` (e.g. `-e 0.10` for 10%,
`-e 0.50` for 50%). Tweak the browser concurrency by changing `-v`
(higher = more parallel sessions in Faro). Tweak the duration by
changing `-d` (seconds). Press `Ctrl+C` to stop all three early.

---

# Appendix — Full Uninstall / Clean Slate

Use this when you want to tear everything down and start fresh — for
example before a clean re-deploy, when switching credentials, or when
the cluster is in a weird state.

The order matters in reverse of install: **apps first, telemetry
second, namespace last**. Uninstalling the telemetry stack before the
apps will leave the app pods stuck in `CreateContainerConfigError`
referencing the missing Pyroscope secret.

## A1 — Uninstall the apps (pov-sim)

```bash
helm uninstall pov-sim -n povsim
```

> **If you originally installed pov-sim without `--namespace povsim`**,
> the release record lives in `default`. Check with `helm list -A`. If
> you see `pov-sim` under namespace `default`, uninstall it there
> instead:
> ```bash
> helm uninstall pov-sim -n default
> ```

## A2 — Remove standalone cAdvisor (OrbStack only)

If you ran Step 4 of the install:
```bash
kubectl delete -f cadvisor/cadvisor-daemonset.yaml
```

## A3 — Uninstall Grafana k8s Monitoring (Alloy)

```bash
helm uninstall grafana-k8s-monitoring -n povsim
```

This also deletes the Pyroscope auth secret
(`grafana-cloud-profiles-grafana-k8s-monitoring`). That's why A1 has to
go first.

## A4 — Delete the namespace

```bash
kubectl delete namespace povsim
```

## A5 — Clean up cluster-scoped orphans

Some resources from the `ingress-nginx` subchart are **cluster-scoped**
and survive a namespace deletion. Helm normally cleans them up via A1,
but if you force-terminated the namespace (see A6) or interrupted an
install mid-flight, they may be left behind and will block the next
install with:

> `ClusterRole "pov-sim-ingress-nginx" exists and cannot be imported into the current release`

Check for and delete them:
```bash
kubectl get clusterrole,clusterrolebinding,ingressclass,validatingwebhookconfiguration 2>/dev/null \
  | grep -iE 'pov-sim|ingress-nginx'

# Then delete each one that showed up, e.g.:
kubectl delete clusterrole               pov-sim-ingress-nginx
kubectl delete clusterrolebinding        pov-sim-ingress-nginx
kubectl delete ingressclass              nginx
kubectl delete validatingwebhookconfiguration pov-sim-ingress-nginx-admission
```

## A6 — Force-terminate a stuck namespace

If `kubectl get ns povsim` shows `Terminating` for more than a minute
or two, the Alloy operator's finalizers are holding it open. Diagnose:
```bash
kubectl get ns povsim -o jsonpath='{.status.conditions}'
```

Typical culprits:
- `helm.sdk.operatorframework.io/uninstall-release` on 5 Alloy CRs
- `k8s.grafana.com/finalizer` on the alloy-operator Deployment

Strip the finalizers off so cleanup can finish:
```bash
# Drop finalizers from the 5 stuck Alloy CRs
kubectl get alloys.collectors.grafana.com -n povsim -o name | \
  xargs -I {} kubectl patch {} -n povsim --type=merge -p '{"metadata":{"finalizers":[]}}'

# Drop the finalizer from the stuck operator Deployment
kubectl patch deploy/grafana-k8s-monitoring-alloy-operator -n povsim \
  --type=merge -p '{"metadata":{"finalizers":[]}}'
```

Within a few seconds:
```bash
kubectl get ns povsim
# Error from server (NotFound): namespaces "povsim" not found
```

**What you give up by force-terminating:** the finalizers exist so the
k8s-monitoring operator can deregister the Alloy collectors from
Grafana Cloud Fleet Management cleanly. After a force-terminate they'll
show as offline in FM — cosmetic, not dangerous, but worth knowing.

## A7 — Verify everything is gone

```bash
kubectl get ns povsim                                        # NotFound
helm list -A | grep -E 'pov-sim|grafana-k8s-monitoring'      # (empty)
kubectl get clusterrole,clusterrolebinding,ingressclass,validatingwebhookconfiguration \
  2>/dev/null | grep -iE 'pov-sim|ingress-nginx'             # (empty)
```

When all three return nothing, the cluster is clean and you can
re-run [Step 1 — Install Grafana k8s Monitoring (Alloy)](#step-1--install-grafana-k8s-monitoring-alloy)
for a fresh deploy.

## A8 — One-shot uninstall script (advanced)

For convenience, here's the whole sequence as a copy-pasteable block.
Run it from the repo root:

```bash
# A1 — uninstall apps (try both namespaces, ignore "not found")
helm uninstall pov-sim -n povsim  2>/dev/null || true
helm uninstall pov-sim -n default 2>/dev/null || true

# A2 — standalone cAdvisor
kubectl delete -f cadvisor/cadvisor-daemonset.yaml --ignore-not-found

# A3 — telemetry
helm uninstall grafana-k8s-monitoring -n povsim 2>/dev/null || true

# A4 — namespace (may take a moment)
kubectl delete namespace povsim --ignore-not-found --wait=false

# A5 — cluster-scoped orphans (safe to retry; --ignore-not-found makes them no-ops if absent)
kubectl delete clusterrole               pov-sim-ingress-nginx                --ignore-not-found
kubectl delete clusterrolebinding        pov-sim-ingress-nginx                --ignore-not-found
kubectl delete ingressclass              nginx                                --ignore-not-found
kubectl delete validatingwebhookconfiguration pov-sim-ingress-nginx-admission --ignore-not-found

# A6 — if the namespace is still Terminating after ~30s, force-finalize
if kubectl get ns povsim 2>/dev/null | grep -q Terminating; then
  kubectl get alloys.collectors.grafana.com -n povsim -o name 2>/dev/null | \
    xargs -I {} kubectl patch {} -n povsim --type=merge -p '{"metadata":{"finalizers":[]}}'
  kubectl patch deploy/grafana-k8s-monitoring-alloy-operator -n povsim \
    --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
fi

# A7 — verify
kubectl get ns povsim
helm list -A | grep -E 'pov-sim|grafana-k8s-monitoring' || echo "(no helm releases — clean)"
```
