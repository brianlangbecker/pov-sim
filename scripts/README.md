# Load generation scripts

Scripts for driving traffic against the `pov-sim` services on the `orbstack`
cluster (namespace `povsim`) — for generating normal load, request spikes,
HTTP errors, and a reproducible `flights` OOMKill. See `../DEMO-VERIFY-OOM.md`
for the full research/validation history behind the OOM demo specifically.

## Quick picks

| I want...                                                      | Run this                                                                                         |
| ---------------------------------------------------------------| ------------------------------------------------------------------------------------------------ |
| A single clean OOM crash, stop once it happens                 | `./flights-loadgen-parallel.sh -t orbstack`                                                      |
| Repeated crashes back-to-back (no recovery gap)                | `./flights-loadgen-parallel.sh -t orbstack -m 30 -k`                                              |
| Crash → recover → crash, visible spike + errors, high request rate (**current recommendation**) | `./flights-loadgen-parallel.sh -t orbstack -o -c 4 -q 45 -n 60 -r 1 -e 0.3` |
| Same pattern, lower request-rate variant (earlier tuning, still valid) | `./flights-loadgen-parallel.sh -t orbstack -o -c 4 -q 45 -n 10 -r 0.4 -e 0.3`          |
| Max aggression — crashes in seconds, too fast to watch a ramp (smoke-test only, **not** for a recorded demo) | `./flights-loadgen-parallel.sh -t orbstack -o -n 25 -r 0 -e 0.3` |
| Plain curl traffic to `flights`, no crash intent                | `./flights-loadgen.sh -t orbstack`                                                                |
| Plain curl traffic to `airlines`                                | `./airlines-loadgen.sh -t orbstack`                                                                |
| Real end-to-end browser trace (frontend → flights → airlines), RUM | `./frontend-loadgen.sh -t orbstack`                                                            |

**Always pass `-t orbstack`.** Every script's default target is `local`
(`http://localhost:<port>`), which nothing outside the cluster can reach —
omitting `-t orbstack` silently sends zero real traffic to the pod (you'll
see the script "running" with no effect at all).

---

## `flights-loadgen.sh`

Single-instance curl loop against the `flights` service. Hits, per loop
iteration: 2 basic `GET` endpoints, 3 `GET /flights/<airline>` calls, 12
`POST /flight` booking calls (17 requests/iteration total), then sleeps 1s
before repeating, for the full `-d` duration.

| Flag | Meaning | Default |
|---|---|---|
| `-t` | Target: `local` or `orbstack` | `local` |
| `-b` | Explicit base URL, overrides `-t` | — |
| `-e` | Fraction of requests that set `?raise=500` (real app exception → HTTP 500) | `0` |
| `-d` | Duration in seconds | `60` |
| `-r` | Delay in seconds after *each* request (on top of the per-iteration 1s sleep) | `0` (unthrottled) |
| `-h` | Help | |

One instance tops out around what the server can serially process per
thread — not very high throughput on its own. Use `flights-loadgen-parallel.sh`
to run many instances concurrently.

**`-e` accuracy fix**: the random-roll used to decide whether a request sets
`?raise=500` had a zero-padding bug (`"0.$((RANDOM % 100))"` produced `"0.5"`
instead of `"0.05"` on ~10% of rolls), which silently skewed the *actual*
error rate low — `-e 0.3` was landing around ~23%, not 30%. Fixed by
zero-padding the roll (`printf '%02d'`); verified in a 200k-iteration
simulation that `-e 0.3` now lands on exactly 0.300. Same bug existed in
`airlines-loadgen.sh` and is fixed there too. No image rebuild needed — these
are host-side bash scripts, not baked into any container image.

```bash
# Plain unthrottled traffic for 2 minutes, no errors
./flights-loadgen.sh -t orbstack -d 120

# 25% error rate
./flights-loadgen.sh -t orbstack -e 0.25 -d 60
```

---

## `flights-loadgen-parallel.sh`

Wraps N concurrent `flights-loadgen.sh` instances and polls the live `flights`
pod for a restart-count increment (i.e. an actual `OOMKilled` crash), so you
never have to guess a duration. Three modes:

1. **Default** — stop the instant the first crash is detected.
2. **`-k` (keep-going)** — log every crash but leave the *same* load running
   continuously through the whole `-m` window, so the pod can OOM repeatedly,
   back-to-back, with no gap.
3. **`-o` (oscillate)** — crash, **stop all load** so the pod drops back to
   idle/normal, wait `-q` seconds, then launch a fresh burst and crash it
   again — repeated `-c` times. This is what you want for a demo that needs
   a clean, readable repeating pattern (spike → crash → quiet → spike →
   crash...) rather than one continuous messy incident.

| Flag | Meaning | Default |
|---|---|---|
| `-n` | Parallel loadgen instances per burst | `10` |
| `-t` | Target: `local` or `orbstack` | `local` |
| `-u` | Explicit base URL, overrides `-t` | — |
| `-e` | Error fraction, passed through to each instance | `0` |
| `-r` | Per-request delay, passed through to each instance | `1.7` |
| `-m` | Safety cap (minutes). Without `-o`: overall give-up time. With `-o`: max wait **per cycle** before giving up on that cycle | `40` |
| `-k` | Keep going after a crash instead of stopping (ignored if `-o` also set) | off |
| `-o` | Oscillate: crash → stop → quiet `-q`s → crash again, × `-c` | off |
| `-c` | Cycles to run in oscillate mode | `4` |
| `-q` | Quiet seconds between cycles in oscillate mode | `45` |
| `-h` | Help | |

### Tuning cheat sheet

The server (`flights`) now runs Werkzeug's dev server with `--with-threads`
(fixed because it was serializing all requests, capping aggregate throughput
at ~8 req/s regardless of client-side concurrency — see `flights/Dockerfile`).
That means **the client side is no longer the bottleneck**, and settings
tuned before that fix will now crash much faster than intended:

- `-r 1.7` (the script's own default) was tuned for a **smooth ~5-10 min
  climb** against the old 256Mi limit, pre-threading. It's now overkill —
  slower than necessary, but still works for "plain, predictable" demos.
- `-r 0` (fully unthrottled) + high `-n` + the current 128Mi limit (see
  `helm-charts/pov-sim/values.yaml`) crashes in well under a minute now —
  too fast to show a readable ramp in most dashboard panels, and `-o`'s 5s
  poll interval can miss a clean "spike then crash" shape entirely.
- **`-n 10 -r 0.4`** is the current best-known balance: ~17 req/s aggregate
  (comfortably above an "8 req/s" visibility bar), a ~45-60s climb to the
  128Mi limit — long enough to see the spike, the errors, and the crash as
  distinct phases, short enough to stay dramatic.
- **Want a higher request-rate spike without speeding up the crash?**
  `flights/app.py`'s `_record_audit_event()` payload sizes (per-booking,
  per-search leak size) and the loadgen's `-n` are a matched pair — total
  leak rate is roughly `instances × payload_size`. Shrinking the payload and
  scaling `-n` up by the same factor keeps crash timing the same while
  multiplying how often the real audit path (`_record_audit_event` /
  `audit-service.record` span) actually fires. Current sizes are `6_700`
  bytes/booking and `50_000` bytes/search (already 6x smaller than the
  original `40_000`/`300_000`) specifically so **`-n 60`** gives ~6x the
  request rate of the `-n 10` recipe above at roughly the same time-to-OOM.
  If you resize the payloads again, rescale `-n` by the inverse ratio.

If you change the memory limit (`helm-charts/pov-sim/values.yaml` →
`flights.resources.limits.memory`) instead, re-tune `-n`/`-r` empirically —
there's no fixed formula that survives a limit change (only a payload-size
change scales predictably, per above).

```bash
# Single clean crash, default pacing, stop once it happens
./flights-loadgen-parallel.sh -t orbstack

# Keep crashing it repeatedly for 20 minutes, no recovery gaps
./flights-loadgen-parallel.sh -t orbstack -m 20 -k

# Crash / recover / crash x4, with errors and a visible spike
./flights-loadgen-parallel.sh -t orbstack -o -c 4 -q 45 -n 10 -r 0.4 -e 0.3

# Same crash timing as above, ~6x the request rate hitting the real audit
# path (matches the current 6_700/50_000 payload sizes in app.py)
./flights-loadgen-parallel.sh -t orbstack -o -c 4 -q 45 -n 60 -r 1 -e 0.3

# Max aggression (fast crash, hard to watch ramp in a dashboard -- use for
# "did this break at all" smoke-testing, not for a recorded demo)
./flights-loadgen-parallel.sh -t orbstack -o -n 25 -r 0 -e 0.3
```

Logs for each instance land in a temp dir printed at startup
(`/tmp/flights-loadgen-parallel.XXXXXX/instance-N.log`, or
`cycle-N-instance-M.log` in oscillate mode).

---

## `airlines-loadgen.sh`

Same shape as `flights-loadgen.sh` but for `airlines` — single-instance curl
loop, no parallel wrapper exists for this one (airlines has no staged
failure mode to trigger).

| Flag | Meaning | Default |
|---|---|---|
| `-t` | Target: `local` or `orbstack` | `local` |
| `-b` | Explicit base URL, overrides `-t` | — |
| `-e` | Fraction of requests that set `?raise=true` (real app exception → HTTP 500) | `0` |
| `-d` | Duration in seconds | `60` |
| `-h` | Help | |

```bash
./airlines-loadgen.sh -t orbstack -e 0.2 -d 90
```

---

## `frontend-loadgen.sh` / `frontend-loadgen.js`

The only script that drives **real browser traffic**. Uses k6's `browser`
module (headless Chromium) to actually load the React app, click through
Airlines and Flights pages, and fire real cross-origin XHR calls — so Faro
RUM events fire and a genuine `frontend → flights → airlines` trace gets
stitched together (confirmed live: `flights` makes a real HTTP call to
`airlines` inside `GET /flights/<airline>`, so this is a true three-hop
trace, not just two independent calls).

Requires k6 with browser support: `brew install k6`.

| Flag | Meaning | Default |
|---|---|---|
| `-t` | Target: `local` or `orbstack` | `orbstack` (not `local` — see note below) |
| `-v` | Parallel browsers (virtual users) | `2` |
| `-d` | Duration in seconds | `600` (10 min) |
| `-h` | Help | |

**Default target is `orbstack`, unlike the curl-based scripts** —
`http://frontend.povsim.svc.cluster.local:3000` is the only origin currently
registered in the Faro app's CORS/collector allow-list in Grafana Cloud.
`localhost:3000` gets silently dropped by the Faro collector rather than
erroring, so it would look like it worked while shipping nothing — don't
override to `-t local` unless you've also updated that allow-list.

```bash
# Default: 2 browsers, 10 minutes, against orbstack
./frontend-loadgen.sh

# 8 parallel browsers for 5 minutes
./frontend-loadgen.sh -t orbstack -v 8 -d 300
```

This is also the slower of the two ways to trigger the `flights` OOM (see
`DEMO-VERIFY-OOM.md` §10) — real browser page-load-and-click cycles are much
lower throughput than curl, so expect minutes, not seconds, per leak
increment if you're trying to crash it this way instead of with
`flights-loadgen-parallel.sh`.

---

## Notes that apply to all of the above

- **No script auto-targets the cluster.** Forgetting `-t orbstack` is the
  single most common failure mode — the script runs, reports success, and
  nothing happens on the pod because it was talking to `localhost`.
- **`flights` has a real, intentional memory leak** (`_booking_history` in
  `flights/app.py`, never trimmed) gated behind a Helm-configured memory
  limit (`helm-charts/pov-sim/values.yaml` → `flights.resources.limits.memory`,
  currently `128Mi`). This is by design for the OOM demo — not a bug to fix.
- Check current pod state before/during a run:
  ```bash
  kubectl get pods -n povsim -l app=flights -w
  kubectl exec -n povsim $(kubectl get pods -n povsim -l app=flights -o jsonpath='{.items[0].metadata.name}') -- cat /sys/fs/cgroup/memory.current
  ```
