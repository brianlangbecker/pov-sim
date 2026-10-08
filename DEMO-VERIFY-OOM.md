# Verify: K8s Monitoring + Logs + Traces Demo (pov-sim)

Staging one failure (OOMKill/CrashLoopBackOff on `flights`) that proves all three
demo success criteria in a single recording.

**Status: done, validated live, and now includes a real cross-service call.**
Everything described below has been applied to the cluster and re-tested
repeatedly. For the current, final setup: **§15** (flights now really calls
airlines) and **§16** (final timing/throttle setup, live-confirmed at 7m57s,
in the 5-10 min target window) are the sections to actually use. §9/§10 cover
the original single-service triggers (still valid, just superseded on timing
by §16); §1-8 are the research and failed early attempts, kept for the record.

## 1. Current Helm config: no resource limits, no crash toggle

- Neither `helm-charts/pov-sim/templates/flights-deployment.yaml` nor
  `airlines-deployment.yaml` has a `resources:` block. `helm-charts/pov-sim/values.yaml`
  only sets `image.repository`/`image.tag`/`image.pullPolicy`/`port`/`replicas` per
  service — no memory/CPU fields anywhere.
- **Consequence: an OOMKill cannot happen today.** With no memory limit, Kubernetes
  has nothing to enforce and nothing to kill against.
- **No crash-trigger toggle exists** (no templated `command`, `args`, or overridable
  `env`/`image.tag` path for injecting a bad value). One has to be added from scratch
  — see the diff in §4.
- Live measurement: current `flights` pod idle steady-state cgroup memory is
  **~74 MiB** (`kubectl exec -n povsim <flights-pod> -- cat /sys/fs/cgroup/memory.current`
  → `77201408` bytes). This anchors the limit chosen in §4.

## 2. Call graph: airlines and flights never talk to each other

> **Superseded by §15**: this was true of the *original* codebase. `flights`
> now makes a real HTTP call to `airlines` (added deliberately, see §15) —
> the finding and implication below describe the starting state this demo
> was built from, not the current one.

- **`airlines` and `flights` do NOT call each other directly.** No non-test
  reference to "flights" exists in `airlines/src` (the only hit is JUnit's
  `TestRestTemplate`, unrelated). `flights/*.py` has zero references to "airlines",
  `requests.`, or `httpx` — it makes no outbound HTTP calls at all.
- **`frontend` calls both backends independently:**
  - `frontend/src/pages/Airlines.js:5,15` — `axios.get(AIRLINES_API_URL)`,
    `AIRLINES_API_URL = REACT_APP_AIRLINES_API_URL || "http://localhost:8080/airlines"`
  - `frontend/src/pages/Flights.js:5,16` — `axios.get(FLIGHTS_API_URL + ...)`,
    `FLIGHTS_API_URL = REACT_APP_FLIGHTS_API_URL || "http://localhost:5001/flights"`
  - `frontend/src/faro.js:29-30` — Faro RUM trace propagation is explicitly configured
    for both `airlines.povsim.svc.cluster.local` and `flights.povsim.svc.cluster.local`.

**Implication:** cross-service correlation in this demo is **frontend-fan-out**,
not backend-to-backend. If the demo script calls for "cross-service impact," that
story has to run through the frontend UI/RUM session, not a direct
flights→airlines (or vice versa) trace hop — there isn't one. A pure backend-only
loadgen hit on `flights` will show a clean, isolated failure with no natural
second-service blast radius unless the frontend is also exercised.

## 3. Trace-to-log linkage: broken today, fixable with a two-line addition

- **airlines** (`airlines/src/main/resources/logback-spring.xml:21-23`): the
  `LogstashEncoder` includes MDC keys `trace_id`, `span_id`, `trace_flags`,
  auto-populated by the OTel Java agent. Emitted as literal `trace_id`/`span_id`
  JSON fields in the stdout body.
- **flights** (`flights/app.py:24-29`): `_JsonFormatter.add_fields` reads
  `record.otelTraceID`/`otelSpanID` (injected by `LoggingInstrumentor`) and writes
  them into the JSON body as `trace_id`/`span_id` — same key names as airlines.
- **Alloy currently does nothing with them.** Both apps set `OTEL_LOGS_EXPORTER=none`
  (logs never leave as native OTLP LogRecords with real trace-context fields —
  they're flat JSON text picked up by Alloy's filelog receiver). The live
  `alloy-logs` OTTL pipeline only promotes `logger_name` out of the JSON body
  (`alloy/povsim-k8s-monitoring-values.yaml:48-50`) — there is no equivalent
  statement for `trace_id`/`span_id`.
- **Verdict: broken.** `trace_id`/`span_id` exist in the raw log body but are not
  Loki attributes/structured metadata. Grafana's log↔trace correlation buttons
  query by attribute, not raw body text, so they return empty today. This directly
  blocks demo success criterion #2 ("the error log line links to a trace") and #3
  ("from that trace, navigate to the correlated log").
- **Fix:** two more OTTL statements mirroring the existing `logger_name` pattern —
  see diff in §4.

## 4. Proposed diffs (unapplied)

Three independent, minimal changes. None has been applied — apply only on
explicit go-ahead.

### 4a. Give `flights` a memory limit it can actually hit

```diff
--- a/helm-charts/pov-sim/values.yaml
+++ b/helm-charts/pov-sim/values.yaml
@@ -13,6 +13,18 @@
     pullPolicy: Never
   port: 5001
   replicas: 1
+  # Idle steady-state cgroup memory measured on the live pod is ~74Mi
+  # (kubectl exec ... cat /sys/fs/cgroup/memory.current). This limit sits
+  # close enough above idle that sustained concurrent load pushes the
+  # container over it, but leaves enough headroom that it survives startup
+  # and a light initial request or two before the OOMKill hits.
+  resources:
+    requests:
+      memory: "64Mi"
+      cpu: "50m"
+    limits:
+      memory: "100Mi"
+      cpu: "500m"
 
 frontend:
   image:
```

```diff
--- a/helm-charts/pov-sim/templates/flights-deployment.yaml
+++ b/helm-charts/pov-sim/templates/flights-deployment.yaml
@@ -22,6 +22,8 @@
           imagePullPolicy: {{ .Values.flights.image.pullPolicy }}
           ports:
             - containerPort: {{ .Values.flights.port }}
+          resources:
+            {{- toYaml .Values.flights.resources | nindent 12 }}
           env:
             - name: PYROSCOPE_APPLICATION_NAME
               value: flights
```

Both hunks validated: `helm template` renders the container `resources:` block
correctly with the patched files.

**100Mi is a starting point, not a guarantee** — see the loadgen sufficiency
caveat in §5. If a dry run doesn't trip it, the fastest lever is lowering
`limits.memory` further (e.g. to 80Mi) rather than rewriting the loadgen script.

### 4b. Fix trace_id/span_id log correlation (independent of the OOM demo, but needed for criteria #2/#3)

```diff
--- a/alloy/povsim-k8s-monitoring-values.yaml
+++ b/alloy/povsim-k8s-monitoring-values.yaml
@@ -40,6 +40,14 @@
           log:
             - 'set(attributes["logger_name"], ParseJSON(body)["logger_name"]) where IsMatch(body, "^\\{") and IsMatch(body, "\"logger_name\"\\s*:")'
             - 'set(attributes["logger_name"], ParseJSON(body)["name"]) where attributes["logger_name"] == nil and IsMatch(body, "^\\{") and IsMatch(body, "\"name\"\\s*:")'
+            # Both apps emit trace_id/span_id as top-level JSON keys (airlines
+            # via logback-spring.xml's MDC includes; flights via app.py's
+            # _JsonFormatter). Without this, Loki never sees them as
+            # attributes/structured metadata, so Grafana's trace<->log
+            # correlation buttons return nothing even though the data exists
+            # in the raw body text.
+            - 'set(attributes["trace_id"], ParseJSON(body)["trace_id"]) where IsMatch(body, "^\\{") and IsMatch(body, "\"trace_id\"\\s*:")'
+            - 'set(attributes["span_id"], ParseJSON(body)["span_id"]) where IsMatch(body, "^\\{") and IsMatch(body, "\"span_id\"\\s*:")'
         traces:
           resource:
             - 'set(attributes["env"], "production") where attributes["env"] == nil'
```

Validated: full YAML parses and `helm template` against the `grafana/k8s-monitoring`
chart succeeds with this file. **This one needs to land before the demo is recorded**
— without it, criteria #2 and #3 cannot be demonstrated regardless of how the OOM
is triggered.

## 5. Loadgen readiness — marginal, needs adjustment

- Script: `scripts/flights-loadgen.sh` (not at repo root).
- **Target URL confirmed correct**: `-t orbstack` sets
  `BASE_URL=http://flights.povsim.svc.cluster.local:5001`, matching the live
  `flights` Service (`kubectl get svc -n povsim flights` → ClusterIP, port
  `5001/TCP`, selector `app=flights`). Must pass `-t orbstack` — the flag-less
  default is `localhost:5001`.
- **Load shape is a problem for a memory-pressure demo**: it's a bash loop doing
  ~17 *sequential* curl calls per ~1s cycle (2 GET + 3 GET-flight + 12 POST-flight),
  single-threaded, no concurrency, no connection reuse pressure, default duration
  60s (`-d 60`). That's roughly 15-17 req/s from one thread — unlikely to reliably
  build enough per-request allocation pressure to tip a 100Mi limit within 1-2
  minutes unless the endpoint itself allocates heavily per request (it doesn't,
  based on `flights/app.py`).
- **Recommendation**: run several instances concurrently for the actual demo,
  e.g. `for i in {1..10}; do ./scripts/flights-loadgen.sh -t orbstack -d 120 & done`,
  and/or lower `limits.memory` further if a dry run shows the pod holding steady.
  Do a dry run before the recording — don't rely on the single-instance script
  alone to trip the limit on the first take.

## 6. Trace→logs / trace→metrics correlation — can't fully verify from this repo

- No `tracesToLogsV2`, `tracesToMetrics`, or datasource-provisioning config exists
  anywhere in this repo. **These correlation settings live only in the Grafana
  Cloud stack UI** (Connections → Data sources → Tempo → "Trace to logs" / "Trace
  to metrics") — they cannot be verified or fixed by reading/editing files here.
  Flagging as an action item to check directly in the stack before recording.
- What can be confirmed from the Alloy config: logs, metrics, and traces all route
  through the single `grafana-cloud-otlp` OTLP destination — there's no local
  `otelcol.exporter.loki`/attribute-to-label mapping in Alloy itself. The
  attribute→label translation happens server-side in Grafana Cloud's OTLP gateway
  (the `helm upgrade` output for this chart literally warns: *"data translated to
  a different storage ecosystem... imperfect translation of labels and
  attributes"*).
- **Known gotcha to check for specifically:** Loki/Prometheus label names cannot
  contain dots. OTel's dotted resource attributes (`service.name`,
  `deployment.environment.name`) get converted to underscores server-side
  (`service_name`, `deployment_environment_name`) — and only a subset of resource
  attributes get promoted to index labels at all; others land as structured
  metadata only. **This cannot be confirmed from this repo** whether
  `deployment.environment.name` specifically made that promotion list.
- **Recommended tag mapping to configure in the Tempo data source** (pending live
  confirmation in the Grafana Cloud UI):
  - `tracesToLogsV2` tags: span attribute `service.name` → Loki label `service_name`
  - `tracesToMetrics` tags: span attribute `service.name` → Prometheus/Mimir label
    `service_name`
- Verify both promotions and the actual correlation config directly against the
  stack before depending on the "Logs for this span" / "Metrics" buttons in the
  recording — task 4's staged OOMKill trace is reusable for this check (no new
  failure needed), but confirm the buttons work in a dry run first.

## 7. What actually worked (superseded plan below in §7a)

The values-only memory-limit approach (100Mi, 80Mi, 72Mi, even 64Mi) **did not
work** — see §8 for the full live test log. This app's memory footprint doesn't
grow under load; cgroup usage just oscillates in a fixed band regardless of
traffic. The fix that worked: a deliberately staged leak in application code.
See §9 for the final, validated runbook — use that one, not the steps below.

## 7a. Original (superseded) runbook

1. Apply the diffs in §4a and §4b (`helm upgrade` for both the `pov-sim` app chart
   and the `grafana-k8s-monitoring` Alloy chart, per each repo's documented upgrade
   command).
2. `kubectl get pods -n povsim -w` in one terminal.
3. Launch load: `for i in {1..10}; do ./scripts/flights-loadgen.sh -t orbstack -d 120 & done`
   (adjust count/duration based on the §5 dry run).
4. Watch for the pod restart / `OOMKilled` reason in the `-w` output and
   `kubectl describe pod <flights-pod> -n povsim` for the event confirmation.
5. **K8s Monitoring app**: cluster → workload (`flights`) → pod → confirm the
   OOMKilled event and the memory-usage-vs-limit graph crossing the line.
6. **Logs**: open the existing logs dashboard/alert, confirm the error burst,
   click into a log line, confirm the trace link now resolves (this is the part
   that was broken before §4b — re-verify it works post-fix).
7. **Traces**: from that trace, use "Logs for this span" and "Metrics" to jump
   back without switching views (per §6, confirm these buttons actually return
   data — if they don't, the Tempo data source correlation tags need fixing in
   the Grafana Cloud UI first).
8. **Frontend path** (since cross-service correlation is frontend-fan-out per §2,
   not backend-to-backend): drive the failure through the frontend UI as well —
   hit the Flights page repeatedly — then check the RUM session in Frontend
   Observability to show the user-facing impact, since `airlines` itself never
   sees any effect from a `flights`-only failure.

## 8. Live test results — the values-only OOM approach doesn't work

Both diffs from §4 were applied and both Helm releases upgraded (`pov-sim` rev 2-4,
`grafana-k8s-monitoring` rev 5). The `trace_id`/`span_id` fix (§4b) is confirmed live
and reloaded. The memory-limit approach (§4a) was tested at three ceilings, each
against a full 120s window of 10 parallel `flights-loadgen.sh -t orbstack` instances:

| Limit tried | Result | Observed memory range during load |
|---|---|---|
| 100Mi | 0 restarts | 74-81MiB, slow creep only (~7MiB/120s) |
| 80Mi | 0 restarts | 71-82MiB, oscillating, no sustained trend |
| 72Mi | 0 restarts | 62-70MiB, oscillating, no sustained trend |
| 64Mi (requests==limits, "guaranteed crash" attempt) | 0 restarts over ~5min | Settled at equilibrium ~58-62MiB, just under the 64MiB ceiling, never crossed |

**Conclusion: this app's memory footprint doesn't grow under load, at any ceiling
tested.** It's not a leak or accumulation problem in the *original* code — request
handling in `flights/app.py` didn't hold onto memory, so cgroup usage oscillated
(GC/allocator noise) and, surprisingly, even self-stabilized just under a tight
64Mi ceiling rather than crossing it (cgroup memory pressure made the allocator/GC
more conservative as it approached the limit). No amount of values-only tuning
produced a reliable load-triggered OOMKill.

Three paths were considered (see conversation): a tighter ceiling below idle (kept
failing per the 64Mi row above), dropping to CrashLoopBackOff via a bad
image/command (rejected — breaks criteria #2/#3 entirely, since a pod that never
serves a request produces no trace and no trace-linked log to correlate), and
adding a deliberate memory-hungry code path. The third option was chosen and is
what actually works — see §9.

## 9. What actually worked: a staged leak in application code

### The fix

`flights/app.py`'s `book_flight()` (`POST /flight`) is the endpoint
`flights-loadgen.sh` calls most (12 times per loop iteration, out of ~17 total
calls). It was changed to append every successful booking to a module-level list
that's never trimmed — a realistic "audit history with no eviction policy" bug,
not a synthetic allocator:

```diff
--- a/flights/app.py
+++ b/flights/app.py
@@ -52,6 +52,15 @@
 Swagger(app)
 CORS(app)

+# BUG (staged intentionally): booking "audit history" with no eviction policy.
+# Every successful booking is appended here and never trimmed, so memory grows
+# monotonically with request volume -- a realistic unbounded-cache leak, not a
+# synthetic allocator. 200KB/booking is sized generously because this app's
+# actual observed throughput under flights-loadgen.sh is low (single-threaded
+# Flask dev server, serial curl clients) -- at even ~3-5 req/s this still
+# clears 50-70MB of growth within ~1-2 minutes, no loadgen changes needed.
+_booking_history = []
+
 @app.route('/health', methods=['GET'])
 def health():
     """Health endpoint
@@ -127,6 +136,12 @@
     passenger_name = request.args.get("passenger_name")
     flight_num = request.args.get("flight_num")
     booking_id = get_random_int(100, 999)
+    _booking_history.append({
+        "booking_id": booking_id,
+        "passenger_name": passenger_name,
+        "flight_num": flight_num,
+        "audit_payload": "x" * 200_000,
+    })
     return jsonify({"passenger_name": passenger_name, "flight_num": flight_num, "booking_id": booking_id}), 200
```

`helm-charts/pov-sim/values.yaml`'s `flights.resources.limits.memory` was set to
**128Mi** (up from the failed 64Mi attempt) — high enough that the pod starts and
runs normally on the ~55-65MiB baseline, but well within reach of the leak under
load.

### Live confirmation

```
Reason:       OOMKilled
Exit Code:    137
Started:      10:00:24
Finished:     10:02:18   (~114s runtime under load)
RestartCount: 1
```

Memory trace during the run: ~50MiB (idle, single background loadgen instance
trickling requests) → jumped to ~126MiB within seconds of launching 10 parallel
`flights-loadgen.sh -t orbstack -d 120` instances → crossed 128Mi and OOMKilled.
Kubernetes restarted the container in place (same pod, `RestartCount` incremented)
per standard pod behavior — and it climbed again immediately afterward since the
loadgen batch was still running, so it can OOM repeatedly if load is sustained.

**Key timing lesson**: a *single* `flights-loadgen.sh` instance is too slow to
matter (~50MiB growth over several minutes) — Flask's dev server processes
requests essentially serially, so the trigger only works with a **parallel batch
of loadgen instances** (10 used here), not the script run alone.

### Exact steps to trigger this manually

```bash
cd /path/to/pov-sim

# 1. Rebuild the flights image with the staged leak (already committed in app.py)
docker build -t pov-sim-flights:latest ./flights

# 2. Make sure the Helm values have the leak-sized limit (128Mi) —
#    already set in helm-charts/pov-sim/values.yaml, flights.resources.limits.memory
helm upgrade --install pov-sim ./helm-charts/pov-sim --namespace povsim

# 3. Force the new image into a running pod (imagePullPolicy: Never + fixed
#    tag means a plain helm upgrade won't pick up a rebuilt image on its own)
kubectl rollout restart deployment/flights -n povsim
kubectl rollout status deployment/flights -n povsim --timeout=60s

# 4. Watch the pod in one terminal
kubectl get pods -n povsim -l app=flights -w

# 5. In another terminal, fire the parallel load batch that actually
#    generates enough throughput to matter (single-instance load is too slow):
chmod +x scripts/flights-loadgen.sh
for i in $(seq 1 10); do
  ./scripts/flights-loadgen.sh -t orbstack -d 120 &
done

# 6. Within roughly 30-120s (varies run to run — it depends on how much of the
#    120s window overlaps with the pod's freshest, lowest-memory state), watch
#    the -w terminal for a RESTARTS count increment, then confirm the reason:
POD=$(kubectl get pods -n povsim -l app=flights -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod -n povsim "$POD" | sed -n '/State:/,/Ready:/p'
# Look for: Last State: Terminated / Reason: OOMKilled / Exit Code: 137
```

If it doesn't trip within ~2 minutes, launch a second parallel batch on top of the
first rather than waiting — the growth is monotonic so it never resets, it's just
a question of aggregate request volume.

### Flow: from "pod blew up" to a correlated log, and from that log to a trace

This is the actual click-path in the Grafana Cloud UI once the OOMKill above has
happened (or is happening):

1. **Start in the K8s Monitoring app.** Cluster → workload `flights` → the pod
   that just restarted. This view shows the `OOMKilled` event directly (Kubernetes
   event stream) and a memory-usage-vs-limit panel where the line visibly hits
   the 128Mi ceiling right before the restart. This is your root-cause confirmation
   for criterion #1 — no further clicking needed to prove *what* killed the pod.
2. **Note the pod name and the approximate timestamp of the restart** from that
   view (or from `kubectl describe pod` in step 6 above).
3. **Jump to Logs (Explore or the existing logs dashboard).** Filter by
   `service_name="flights"` (or `pod` if that label is present — check via
   `{service_name="flights"} | json` in Explore first to see the actual label set,
   since §6 flagged that the exact promoted-label list isn't confirmable from
   this repo) and narrow the time range to the ~30s window ending at the restart
   timestamp. You will NOT find an app-level "OOM" log line — the kernel kills the
   process abruptly, so the app never gets to log its own death. What you *will*
   find:
   - A dense burst of successful `POST /flight` booking log lines right up until
     the log stream stops abruptly (the burst itself, ending mid-stream, is the
     visible signature of the crash in Logs).
   - If `clusterEvents`/`alloy-singleton` log shipping is working (it's enabled in
     `alloy/povsim-k8s-monitoring-values.yaml`), a separate Kubernetes-event log
     line for the OOMKill itself, distinct from the app's own logs.
   - Immediately after: a fresh burst of startup log lines from the restarted
     container.
4. **Pick any booking log line from just before the cutoff and expand it.** It
   will carry `trace_id`/`span_id` attributes (confirmed working after the §4b
   fix — these are NOT present in the raw body text as labels/attributes without
   that fix, so if you don't see them, the Alloy upgrade in step 2 of "trigger
   manually" above didn't actually land — re-check the configmap).
5. **Click the trace-correlation button on that log line** ("View trace" / trace
   ID link, exact label depends on Grafana Cloud UI version) to jump to that
   request's span in Tempo.
6. **From the trace view**, use "Logs for this span" to jump back to the same log
   line from the other direction, and "Metrics" to jump to the memory/request-rate
   metrics for that service — **this is the part flagged as unverified in §6**:
   whether these buttons return data depends on `tracesToLogsV2`/`tracesToMetrics`
   tag configuration in the Grafana Cloud Tempo data source (not stored in this
   repo), and specifically whether `service_name` (or whatever the real promoted
   label turns out to be per step 3) is what's configured there. If these buttons
   return empty, that configuration — not anything in this codebase — is what
   needs fixing, directly in Connections → Data sources → Tempo in the Grafana
   Cloud UI.
7. **Frontend/RUM leg** — see §10 below for a fully validated version of this
   (not just "optional" — it's now a second complete trigger path, not only an
   add-on to the curl-driven one).

## 10. Second validated path: trigger via frontend-loadgen.sh (browser-driven)

The curl-driven trigger in §9 is fast (~2 min) but not very compelling to
narrate — nobody is watching a curl loop. This path drives the exact same leak
through real headless-Chromium clicks on the actual UI, so the demo story is
"a user browsing the site is what kills the backend" — with a Faro RUM session
to show for it afterward.

### Prerequisite: the leak has to live where the frontend can reach it

The frontend never calls `POST /flight` (the endpoint §9's leak was built into)
— there's no booking UI at all. It only calls `GET /flights/<airline>` (the "Get
{airline} Flights" button on the Flights page). So the same staged-leak pattern
was **also** added to `get_flights()` in `flights/app.py`, appending to the same
`_booking_history` list:

```diff
     status_code = request.args.get("raise")
     if status_code:
       raise Exception(f"Encountered {status_code} error") # pylint: disable=broad-exception-raised
     random_int = get_random_int(100, 999)
+    _booking_history.append({
+        "airline": airline,
+        "result": random_int,
+        "audit_payload": "x" * 1_500_000,
+    })
     return jsonify({airline: [random_int]}), 200
```

1.5MB per call (vs. 200KB for the POST endpoint) because browser-driven traffic
is much lower-throughput than curl — each k6 VU does a full page-load-and-click
cycle (several seconds) instead of a sub-100ms HTTP call, so each call needs to
count for more.

### A real, pre-existing bug this surfaced: `frontend-loadgen.js`'s selector was broken

Running `frontend-loadgen.sh` for the first time revealed that **it has never
actually been hitting the backend** for the Flights page, independent of
anything to do with this OOM work. `scripts/frontend-loadgen.js` clicks
`button.app-btn` on both the Airlines and Flights pages — but Airlines renders
exactly one such button while Flights renders three (one per airline: AA/DL/UA).
Playwright's (and k6/browser's) strict-mode click throws on an ambiguous
selector, so every single Flights-page click failed silently in the background
with `Uncaught (in promise) clicking on "button.app-btn": strict mode violation,
multiple elements returned for selector query` — meaning `GET /flights/<airline>`
was never actually called by this script before now, RUM traces notwithstanding.
Fixed with `.first()`:

```diff
     await page.locator('a[href="/airlines"]').click();
-    await page.locator('button.app-btn').click();
+    await page.locator('button.app-btn').first().click();
     await page.waitForLoadState('networkidle');
     sleep(1);

     await page.locator('a[href="/flights"]').click();
-    await page.locator('button.app-btn').click();
+    await page.locator('button.app-btn').first().click();
     await page.waitForLoadState('networkidle');
     sleep(1);
```

### Live confirmation

```
Reason:       OOMKilled
Exit Code:    137
Started:      10:26:41
Finished:     10:32:45   (~6m4s runtime — slower than §9's curl trigger, as expected)
```

Ran again immediately afterward (Kubernetes auto-restarted the container) and
climbed back to ~127MiB/128Mi within another few minutes under the same
still-running load — confirmed repeatable, not a one-off.

### Exact steps to trigger this manually

```bash
cd /path/to/pov-sim

# 1. Rebuild the flights image (both leaks — POST and GET — are in app.py already)
docker build -t pov-sim-flights:latest ./flights

# 2. Roll out the new image (same reason as §9 -- imagePullPolicy: Never + fixed tag)
kubectl rollout restart deployment/flights -n povsim
kubectl rollout status deployment/flights -n povsim --timeout=60s

# 3. Make sure k6 is installed with browser support (it bundles Chromium via Playwright)
brew install k6   # if not already installed
which k6 && k6 version

# 4. Watch the pod in one terminal
kubectl get pods -n povsim -l app=flights -w

# 5. In another terminal, launch the browser-driven load
chmod +x scripts/frontend-loadgen.sh
./scripts/frontend-loadgen.sh -t orbstack -v 8 -d 150

# 6. Confirm the crash once RESTARTS increments in the -w terminal:
POD=$(kubectl get pods -n povsim -l app=flights -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod -n povsim "$POD" | sed -n '/State:/,/Ready:/p'
# Look for: Last State: Terminated / Reason: OOMKilled / Exit Code: 137
```

This one takes longer than §9 (budget ~5-6 minutes, not ~2) — don't cut the
recording short. If it hasn't tripped by the time the script's own duration
(`-d 150`) ends, just run it again; growth is cumulative across runs since the
leak never clears until the pod restarts.

### Extra payoff: Frontend Observability / RUM

Because this path drives a real browser through the actual React app, check
Frontend Observability in Grafana Cloud after (or during) the crash window for
the RUM session — failed/slow requests to the Flights API should show up there
tied to the same time window as the OOMKill, giving you a fourth pane (RUM) on
top of the original three, for free.

## 11. Grafana Cloud demo walkthrough — step by step

The click-path, written for actually running the demo live. Menu wording can
shift slightly between Grafana Cloud releases — if a label below doesn't match
exactly what you see, it's almost always a rename of the same feature, not a
missing one. Anywhere this is genuinely unverified (not just "might be worded
differently"), it's called out explicitly rather than assumed.

### 0. Before you hit record

- Have two terminals ready: one running `kubectl get pods -n povsim -l app=flights -w`,
  one free to run the trigger from §9 or §10.
- Open Grafana Cloud in the browser, logged into the stack this cluster reports
  to (`GRAFANA_STACK_ID` in `alloy/.env`).
- Pre-open three browser tabs so you can cut between them live instead of
  navigating on camera: **Kubernetes**, **Logs**, **Traces** (add a fourth,
  **Frontend Observability**, if you're using the §10 browser-driven trigger).
- Note the current wall-clock time — you'll need it to narrow time ranges once
  the crash happens, since "Last 5 minutes" will keep sliding as you talk.

### 1. Trigger the failure

Run either §9 (curl, ~2 min) or §10 (browser, ~5-6 min) in your second
terminal. Narrate while it runs — this is dead air otherwise. Watch the first
terminal for `RESTARTS` to increment; that's your cue to start switching tabs.

### 2. Kubernetes app — confirm root cause (criterion #1)

1. Main nav → **Observability** → **Kubernetes** (sometimes surfaced as
   **Infrastructure → Kubernetes** depending on stack config).
2. Select the **orbstack** cluster (this is `cluster.name` from
   `alloy/povsim-k8s-monitoring-values.yaml` — should be the only cluster
   listed unless the stack has others reporting in).
3. Drill into **Workloads** → **flights** (Deployment). This view aggregates
   across pod replicas/restarts, which is useful context, but the specific
   crash detail is one level deeper.
4. Click through to the **pod** that just restarted (matches the name you saw
   flip in the `-w` terminal). Two things to point at here:
   - The **memory usage vs. limit** panel: you should see the line climb and
     hit the 128Mi ceiling right at the timestamp of the restart.
   - The **events/restart** panel or pod detail: look for `OOMKilled` and
     `Exit Code: 137` surfaced directly — this is the single-pane root-cause
     confirmation for criterion #1, no log/trace digging required yet.

### 3. Logs app — find the burst, get a trace_id (criterion #2)

1. Main nav → **Observability** → **Logs**, or use **Explore** with the Loki
   datasource directly if the Logs app's UI doesn't give you enough query
   control.
2. Query: `{service_name="flights"}` — confirmed live earlier in this exercise
   that this is the correct label from this OTLP→Loki pipeline. If nothing
   returns, try `{service_name="flights"} | json` to also see structured
   fields, or fall back to browsing labels in the UI to find the exact one
   (label promotion is done server-side by the OTLP gateway and can vary by
   Grafana Cloud version — see §6's caveat).
3. Narrow the time range to roughly ±30s around the restart timestamp from
   step 2. You will NOT find an app-level "OOM" log line — the kernel kills the
   process abruptly, so the app never gets to log its own death. What you
   should see instead:
   - A dense burst of successful request log lines (booking or flight-search,
     depending on which trigger you used) that cuts off abruptly mid-stream —
     **that cutoff is the visible signature of the crash** in this view.
   - Possibly a separate Kubernetes-event log line for the OOMKill itself, if
     `clusterEvents`/`alloy-singleton` shipping is active — distinct from the
     app's own log stream, so don't expect it in the same query.
   - A fresh burst of startup log lines starting immediately after.
4. Expand a log line from just before the cutoff. Confirm it carries
   `trace_id` and `span_id` fields/attributes — this only works because of the
   Alloy OTTL fix in §4b/§9; if they're missing, the Alloy upgrade didn't land
   and this whole step will dead-end.
5. Click the trace-correlation control on that log line (exact label varies —
   "View trace", "Related traces", or a trace ID rendered as a link) to jump
   into Tempo. This is the literal criterion #2 handoff: log line → trace.

### 4. Traces app — cross-service view and jump back (criterion #3)

1. You should land directly in the trace view from step 3's click-through. If
   navigating manually instead: main nav → **Observability** → **Traces**, then
   search by the `trace_id` you copied from the log line.
2. Point out the span waterfall — this is where "cross-service impact" would
   show up **if** the failure crossed services. Per §2, `airlines` and
   `flights` never call each other directly, so on a `flights`-only failure
   this trace will just show the single `flights` service's own spans (HTTP
   request → handler). If you're demoing the §10 browser-driven trigger, the
   trace *does* span two hops — `frontend` → `flights` — since the browser's
   XHR call is the request that produced this trace in the first place; that's
   the "cross-service" story to narrate for that path.
3. Try the **"Logs for this span"** and **"Metrics"** buttons on the span
   detail panel. **This is the one part of the walkthrough that's unverified
   ahead of time** (§6): whether these return data depends on
   `tracesToLogsV2`/`tracesToMetrics` tag configuration on the Tempo data
   source in Connections → Data sources, which lives only in the Grafana Cloud
   UI, not this repo. Do a dry run of specifically this click before recording
   — if it comes back empty, fix the tag mapping there (recommended mapping
   per §6: `service.name` → Loki/Prometheus label `service_name`) rather than
   troubleshooting anything in this codebase.

### 5. Frontend Observability — only if you used §10's browser trigger

1. Main nav → **Observability** → **Frontend Observability** (or
   **Application** → **Frontend**, depending on stack layout).
2. Select the `frontend` app (Faro app name — check
   `frontend/src/faro.js` if you need to confirm the exact app key configured).
3. Filter to the same time window as the crash. Look for RUM sessions with
   failed or slow XHR calls to the flights API — this is the "what did the
   user actually experience" close to the loop: browser click → backend leak →
   OOMKill → the same browser session showing a failed request.

### 6. Wrap-up talking points

- Root cause confirmed in one pane (Kubernetes app), without needing logs or
  traces at all — that's the value of criterion #1 in isolation.
- The error burst in Logs and the trace it links to are what let you go from
  "the pod died" to "here's exactly what it was doing when it died," including
  which specific request/session was in flight.
- (§10 path) Frontend Observability closes the loop back to the actual user
  experience, which is the piece K8s Monitoring and Logs alone can't show.

## 12. Re-validated after the CORS fix + mock audit-service span

Two more changes landed on top of §9/§10's leak, both in `flights/app.py`:

- **CORS fix**: `CORS(app, allow_headers=["Content-Type", "traceparent", "tracestate", "baggage"])`.
  Flask-CORS's bare `CORS(app)` doesn't echo the W3C trace-context headers
  Faro injects back in the preflight response, so the browser was silently
  dropping `traceparent` from the actual request. The GET/POST call still
  succeeded either way — that's why flights always showed up with its own
  span even before this fix — but that span was a lone, unstitched root span
  instead of being linked into the frontend's trace. This is what was behind
  the "I get a trace but it only has one line for flights" symptom.
- **Mock `audit-service.record` span**: both `get_flights()` and
  `book_flight()` now call a shared `_record_audit_event()` helper that wraps
  the actual leak (`_booking_history.append(...)`) in a manual `CLIENT`-kind
  span named `audit-service.record`, tagged with `peer.service=audit-service`
  and `audit.record_size_bytes`. This exists purely so the trace waterfall
  has more than one flat line — Flask's auto-instrumentation alone only
  produces a single request span here, since the handlers don't call any
  library OTel already instruments (no outbound HTTP, no DB, no template
  render). The span makes the demo narratable: point at it and say "this is
  what's silently piling up" instead of hand-waving at a flat trace.

### Live re-confirmation

Rebuilt the image, rolled it out, sent a single sanity request (`GET
/flights/AA` → `200`, clean logs, zero exceptions), then fired 10 parallel
`flights-loadgen.sh -t orbstack -d 120` instances against it:

```
restarts: 0 -> 4 over the run
each cycle: OOMKilled / Exit Code: 137
error_lines in pod logs: 0 (confirmed via grep -icE "error|exception|traceback")
```

Zero errors confirms the CORS change and the new span-wrapping code are not
themselves buggy — the crash is still purely the intended memory leak, not a
new bug introduced by this round of changes.

### Pacing note for the actual recording

This validation run crash-looped **very fast** — each life only lasted ~7-8
seconds before the next `OOMKilled`. That's not a change in the leak's
behavior; it's because all 10 loadgen instances were launched simultaneously
against a pod that was still draining stale, hung requests left over from the
*previous* test run (visible as orphaned `curl` processes on the client side
that had to be force-killed separately from the loadgen scripts themselves).
Once those were cleared and load stopped, memory settled and held flat at
~88MiB — confirming the leak is genuinely load-driven, not a startup bug.

**For a clean recording**: don't stack test runs back-to-back. Let the pod
sit idle for a few seconds after any previous run before launching load, and
expect the "normal" first life to run closer to the ~2 min (curl) / ~5-6 min
(browser) budgets from §9/§10 — the ~7s crash-loop above is an artifact of
this specific back-to-back validation sequence, not the expected pacing for
a single clean take.

## 13. Proving the OOM is actually caused by the audit-service span

The K8s Monitoring memory graph and the `OOMKilled` event (§9/§10 step 2)
prove *that* the pod ran out of memory. To prove *why* — that it's
specifically the `audit-service.record` calls accumulating, not something
else — use the trace data itself as evidence, in Traces (Explore or the
Traces app, Tempo datasource):

1. **Search for the span by name**, not just by service:
   ```
   { name = "audit-service.record" }
   ```
   or, more specifically, scoped to the flights service and the mock peer tag:
   ```
   { resource.service.name = "flights" && span.peer.service = "audit-service" }
   ```
2. **Sort results by start time and look at the count within the crash
   window** (the ~30s-2min leading up to the `OOMKilled` timestamp from the
   K8s Monitoring panel). A dense, unbroken run of `audit-service.record`
   spans ending exactly at the crash timestamp — with no corresponding drop
   in request volume beforehand — is the direct evidence: the app was still
   accepting and recording requests at a steady rate right up until it died,
   which rules out "it was already failing/slowing down for some other
   reason before the OOM."
3. **Open a few of those spans and check the `audit.record_size_bytes`
   attribute.** It'll read `1500000` for spans from `get_flights()` (frontend
   path) or `200000` for spans from `book_flight()` (curl path). Multiply
   that by the approximate span count in the window and compare it to the
   actual memory delta from the K8s Monitoring graph (baseline ~55-65MiB up
   to the 128Mi limit, so roughly 65-75MB of growth) — they should land in
   the same ballpark. If the arithmetic roughly checks out
   (`record_size_bytes × count ≈ observed memory growth`), that's a
   quantitative link between "this specific span" and "this specific
   crash," not just a correlation-in-time argument.
4. **Contrast with a span that ISN'T the cause**: open the parent Flask
   request span (the one wrapping `audit-service.record`) and note it has no
   `record_size_bytes`-style attribute and nothing else large-looking — the
   parent span is cheap; all the "weight" is specifically in the child. This
   is the moment in the demo to say "the request itself is trivial — it's
   this one child call that's the problem," pointing at the one line that
   actually matters instead of leaving the audience to guess which part of
   the trace is significant.
5. **If your stack has span metrics / TraceQL metrics enabled** (not
   confirmed for this stack — check Traces app settings or try a query like
   `{ name = "audit-service.record" } | rate()` in Explore), you can plot
   the *rate* of `audit-service.record` calls as a time series directly
   alongside the K8s Monitoring memory panel for a single combined visual,
   rather than eyeballing counts from a span list. Treat this as a nice-to-have
   — the span-list approach in steps 1-4 works regardless of whether this
   feature is available.

## 14. Real bug found and fixed: flights logs never actually carried trace_id

While preparing the demo, checking flights' logs directly revealed that
**no log line ever carried a real `trace_id`/`span_id`**, despite the §4b/§9
Alloy OTTL fix being correctly deployed. This turned out to be two separate,
compounding bugs entirely inside `flights/app.py` / `flights/Dockerfile` —
nothing wrong with Alloy at all. Root-caused live by exec'ing into the
running pod and reading the installed `opentelemetry-instrumentation-logging`
source directly rather than guessing.

### Bug 1: wrong environment variable

`flights/Dockerfile` set `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true`.
That variable only controls whether this package skips installing its handler
in favor of the SDK's deprecated one — it does **not** inject trace context
into log records. The actual switch, confirmed by reading the installed
package's source (`_instrument()` in
`opentelemetry/instrumentation/logging/__init__.py`), is:

```python
set_logging_format = kwargs.get(
    "set_logging_format",
    environ.get(OTEL_PYTHON_LOG_CORRELATION, "false").lower() == "true",
)
```

Without `OTEL_PYTHON_LOG_CORRELATION=true`, the patched `LogRecordFactory` is
installed but is a permanent no-op — it never sets `otelTraceID`/`otelSpanID`
on any record, regardless of whether a span is active. Fixed by adding
`ENV OTEL_PYTHON_LOG_CORRELATION=true` to the Dockerfile.

### Bug 2: even with #1 fixed, the only log line that existed fires after the span already closed

Before this round of fixes, `flights/app.py` had **zero application-level log
statements** inside its route handlers — the only log line produced per
request was werkzeug's own built-in access log (`"GET /flights/AA HTTP/1.1"
200 -"`), emitted from `BaseHTTPRequestHandler.handle_one_request()`. That
call happens *after* `run_wsgi()` has already returned, by which point OTel's
WSGI instrumentation has already closed the request span. So that line would
always show `otelTraceID`/`otelSpanID` as `"0"` (the factory's explicit
default when no span is active), no matter what else was fixed.

Confirmed live: `record_factory` (from the same source read above) sets
`record.otelSpanID = "0"` / `record.otelTraceID = "0"` unconditionally first,
then overwrites with real values only `if span != INVALID_SPAN`. So every log
line now gets *some* value — real hex IDs if a span was open when that
specific line was logged, `"0"` if not. That's the mechanism behind "some
lines have it, some don't": it's not random, it's exactly which code path
logged each line.

**Fix, in two parts:**
1. Added explicit `_app_logger.info(...)` calls inside `get_flights()` and
   `book_flight()`, positioned before the handler returns — while the span is
   still open.
2. Silenced werkzeug's own access log entirely
   (`logging.getLogger("werkzeug").setLevel(logging.ERROR)`) and replaced it
   with a Flask `@app.after_request` hook that logs `"{method} {path} ->
   {status}"` — `after_request` hooks run inside Flask's request dispatch,
   which is inside the WSGI call OTel wraps, so the span is still open there
   too, unlike werkzeug's own post-`run_wsgi()` logging.

### Live confirmation

After both fixes, every single log line from a real request carries matching
`trace_id`/`span_id` — including the access-log replacement:

```json
{"name": "flights.app", "message": "Booked flight_num=404 booking_id=905",
 "trace_id": "9aded325d6ede7daf20dda7dbd3d5609", "span_id": "2a4a417a7dc0e69e", ...}
{"name": "flights.app", "message": "POST /flight -> 200",
 "trace_id": "9aded325d6ede7daf20dda7dbd3d5609", "span_id": "2a4a417a7dc0e69e", ...}
```

No more werkzeug lines, no more `"0"` lines. Both log lines for the same
request share the same `trace_id`/`span_id`, confirming they're correctly
tied to the same span.

### Correction to §2 and §6: airlines does have CORS, just not checked for header-stripping

Earlier research (§2) said airlines has no CORS config at all — that was
wrong, caused by grepping for the literal substring `"cors"` (case-insensitive),
which doesn't match `@CrossOrigin` (the "cors" substring isn't present in that
spelling). `AirlinesController.java:9` has:
```java
@CrossOrigin(origins = {"http://localhost:3000", "http://frontend.povsim.svc.cluster.local:3000"})
```
Spring's `@CrossOrigin` defaults `allowedHeaders` to `*` (all headers allowed)
unlike Flask-CORS's bare `CORS(app)`, which does not echo custom headers back
by default (that gap is what §12's CORS fix addressed for flights). So
airlines likely does **not** have the same header-stripping problem — but
this is not yet confirmed live, and airlines currently has **zero** log
statements in `AirlinesController.java` at all, which is the more basic
version of Bug 2 above (no line exists yet to even check for trace context).
Not yet investigated further — flagged as follow-up if trace/log correlation
for airlines specifically becomes part of the recording.

### If setting up a Loki Derived Field for this manually

Grafana's "TraceID" click-to-trace affordance in Explore/Logs is a separate
piece of config from anything above — it lives on the Loki data source
(Connections → Data sources → Loki → Derived fields) and is not something
Alloy or app code can set. A regex targeting the exact field name is more
robust than a loose case-insensitive one (which will happily match `otelTraceID`
instead of `trace_id` if it appears earlier in the line — harmless while both
hold the same value, but fragile):
```
"trace_id":\s*"(\w+)"
```
Note the `\s*` — `python-json-logger`'s default `json.dumps` output puts a
space after every colon (`"trace_id": "abc..."`, not `"trace_id":"abc..."`),
so any regex assuming no space there (e.g. `"?[:=]"?` with nothing in between)
will silently fail to match anything, which is exactly what happened when
this was first tried.

## 15. flights now really calls airlines — a genuine cross-service trace

§2's finding ("airlines and flights never talk to each other") was true of the
original codebase, but it meant the only cross-service story available was
frontend-fan-out (§10), which requires the browser-driven trigger and doesn't
demonstrate a backend-to-backend dependency at all. Fixed by giving
`get_flights()` a real reason to call `airlines`.

### The change

`flights/app.py` gained `_fetch_operating_airlines()`, called at the top of
`get_flights()`: a genuine `requests.get()` to airlines' `/airlines` endpoint
(`http://airlines.povsim.svc.cluster.local:8080/airlines`, overridable via
`AIRLINES_API_URL`), checking which airlines are currently operating before
returning search results. `requests` was added explicitly to
`requirements.txt` (was present only transitively before — pinning it
directly guarantees `opentelemetry-bootstrap`'s auto-install of
`opentelemetry-instrumentation-requests` keeps working).

No manual span code needed on either side, unlike §9's `audit-service.record`
mock span: `requests`' OTel auto-instrumentation creates a real CLIENT span
and propagates the `traceparent` header, and airlines' OTel Java agent
auto-continues that trace as a SERVER span. This is a genuine network hop —
the only thing in this repo that ever makes flights and airlines part of the
same trace.

### A matching gap found and fixed on the airlines side

Confirmed live that the call succeeded (flights got back the correct
`['AA', 'DL', 'UA']`) but **airlines logged nothing at all** for it — Spring
Boot's embedded Tomcat doesn't emit a routine access log for successful
requests the way werkzeug did for flights before §14's fix, and
`AirlinesController.java` had zero application-level log statements. Fixed
the same way as §14 fixed flights: added a logger and an explicit
`log.info(...)` call inside `getUserById()` (the `/airlines` handler), logged
while the span is still open. Unlike flights, no extra Java-side
"correlation" environment variable was needed — `logstash-logback-encoder` +
MDC (auto-populated by the OTel Java agent) picks up trace context on any
`log.info()` call made while a span is active, no separate opt-in flag.

### Live confirmation: matching trace_id on both sides

```
flights:  trace_id: 8336ee843e5f65c727eac8ca38bdcb0f  span_id: 43eb3a6f3bf6f712
airlines: trace_id: 8336ee843e5f65c727eac8ca38bdcb0f  span_id: 1b03627b6c78ed39
```

Same trace, two different spans — a genuine parent (flights, CLIENT span) /
child (airlines, SERVER span) relationship across services, both sides
carrying a real log line tied to that trace. This means the Grafana Cloud
walkthrough in §11 step 4 no longer needs the caveat that a `flights`-only
trigger shows just a single-service trace — **the curl-driven trigger (§9,
now §16) produces a real two-hop trace on every request**, not only the
browser-driven one.

## 16. Final validated timing setup: 5-10 minute crash, on demand

§9's original timing (~2 min) and an attempt to stretch it by shrinking the
payload further (§9's sizes were already reduced once) both ran into the
same wall: **aggregate loadgen throughput varies wildly run to run** — live
tests with byte-for-byte identical settings crashed anywhere from 38 seconds
to 3 minutes 42 seconds. Raising the memory limit alone didn't fix this
(doubling it to 256Mi still crashed in 48s on one run) because the variance
in *rate* can swamp a fixed change in *distance*. The actual fix was making
the request rate itself consistent instead of leaving it to curl/network
jitter.

### The changes

1. **`scripts/flights-loadgen.sh`** gained an opt-in `-r <seconds>` flag
   (default `0`, so every other use of this script is unaffected): sleeps
   that many seconds after each individual request (17 requests per loop
   iteration: 2 basic GET, 3 GET-flight, 12 POST-flight).
2. **`scripts/flights-loadgen-parallel.sh`** (the "slam script") defaults
   `-r` to `1.7` and passes it straight through — since throttling
   throughput is this script's entire reason to exist, unlike the base
   script which other things may use unthrottled.
3. **Rewritten to run continuously for the entire window** instead of
   relaunching short batches every N seconds: one launch of `-n` instances,
   each running for the full `-m` (max-minutes) duration, polled every 5s
   for a restart-count increment. No batch-relaunch gaps in traffic, no
   duration to guess — it runs exactly as long as necessary and stops itself
   the moment `kubectl` reports a crash (or gives up cleanly past the safety
   cap, with a clear message, if the pod never crashes).
4. **`helm-charts/pov-sim/values.yaml`**: `flights.resources.limits.memory`
   raised to **256Mi** (from 128Mi) — more total distance to travel, so the
   crash timing is less sensitive to short-term rate noise.

### Live confirmation

```bash
./scripts/flights-loadgen-parallel.sh -t orbstack
```
Ran for the full climb with the throttle active, growth tracked closely
against the calculated estimate the whole way (~0.48 MiB/s observed vs.
~0.45 MiB/s calculated), and:
```
CRASH DETECTED at t+477s (7m57s) -- pod flights-6bb76cc44-5lctz restartCount 1 -> 2
Reason: OOMKilled
Exit Code: 137
```
7m57s — centered in the 5-10 minute target window. Re-run after rewriting
the script to remove the batch-relaunch structure and confirmed it still
launches and polls correctly end to end (same underlying rate mechanics, so
timing should be equal or very slightly faster with the relaunch gaps gone).

### How to trigger this (the current, final version)

```bash
cd pov-sim
chmod +x scripts/flights-loadgen.sh scripts/flights-loadgen-parallel.sh

# Rebuild/redeploy first if these are fresh checkouts -- otherwise skip
# straight to launching the trigger against an already-deployed cluster:
docker build -t pov-sim-flights:latest ./flights
docker build -t pov-sim-airlines:latest ./airlines
helm upgrade --install pov-sim ./helm-charts/pov-sim --namespace povsim
kubectl rollout restart deployment/flights deployment/airlines -n povsim
kubectl rollout status deployment/flights -n povsim --timeout=60s
kubectl rollout status deployment/airlines -n povsim --timeout=90s

# Watch in one terminal:
kubectl get pods -n povsim -l app=flights -w

# Trigger in another -- runs until it actually crashes, no duration to guess:
./scripts/flights-loadgen-parallel.sh -t orbstack
```

If a run happens to land outside 5-10 min again (rate noise can still push
it either direction, just with a smaller spread than before 256Mi + the
throttle), rerunning is cheap — nothing about the setup is one-shot.

## Constraints honored

- Every change (app code, Helm values, Alloy config) was shown as a diff and
  confirmed before being applied — nothing was pushed to the cluster without
  explicit go-ahead at each step.
- Nothing pushed to the cluster.
