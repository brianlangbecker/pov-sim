#!/bin/bash

# USAGE
#
# Runs multiple concurrent instances of flights-loadgen.sh continuously --
# one single launch that runs for the entire safety-cap window, not batches
# relaunched every N seconds -- while polling the live `flights` pod in the
# `povsim` namespace for a restart-count increment. This avoids any gap in
# traffic between relaunches. A single instance is too slow to build
# meaningful memory pressure on the flights service (Flask's dev server
# processes requests essentially serially); this wraps N parallel instances
# so aggregate throughput is high enough to trip the memory limit. See
# DEMO-VERIFY-OOM.md.
#
# By default the script stops the instant it detects the first crash. Pass
# -k to keep the load running through the full -m window instead, logging
# every subsequent crash as the pod OOMs and restarts repeatedly.
#
# Pass -o for OSCILLATE mode instead: crash, stop the load so the pod goes
# back to normal (quiet for -q seconds), then launch a fresh burst and crash
# it again, repeated -c times. This is what you want for a demo that needs
# a clearly readable saw-tooth in request-rate/error-rate/memory panels --
# -k's continuous hammering just crash-loops back-to-back with no "back to
# normal" gap, which reads as one messy incident, not a repeating pattern.
#
# Requires kubectl configured against the cluster running the `flights`
# deployment in namespace `povsim`.
#
# To run the script:
# ./flights-loadgen-parallel.sh
#
# Target OrbStack with 10 instances, no time limit other than the safety cap:
# ./flights-loadgen-parallel.sh -t orbstack -n 10
#
# Keep slamming it for 30 minutes, logging every OOM instead of stopping
# at the first one:
# ./flights-loadgen-parallel.sh -t orbstack -m 30 -k
#
# Crash it, let it recover, crash it again -- 4 times, with a mix of HTTP
# 500s along the way, high concurrency and low per-request delay for a
# sharp request-rate spike instead of a smooth ramp:
# ./flights-loadgen-parallel.sh -t orbstack -o -c 4 -q 45 -n 25 -r 0.1 -e 0.3
#
# Run help command to see details and usage options:
# ./flights-loadgen-parallel.sh -h

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADGEN="$SCRIPT_DIR/flights-loadgen.sh"

DEFAULT_INSTANCES=10
DEFAULT_TARGET=local
DEFAULT_ERROR_RATE=0
DEFAULT_MAX_MINUTES=40
# 1.7s of deliberate per-request pacing (passed through as flights-loadgen.sh's
# -r) is what actually makes the crash timing reliable. Without it, aggregate
# throughput across 10 unthrottled parallel instances is dominated by
# curl/network jitter, not by anything we control -- live-tested runs with
# identical settings crashed anywhere from 38s to 3m42s. With this throttle,
# aggregate leak rate is ~10 instances x 1.38MB/iteration (12x40KB POST +
# 3x300KB GET) / (17 requests x 1.7s + 1s trailing sleep) =~ 0.45MB/s, which
# against a 256Mi limit (~196MB of growth budget above the ~60MB baseline)
# targets a ~7min crash -- live-confirmed at 7m57s -- centered in the 5-10
# min window this was tuned for.
DEFAULT_REQUEST_DELAY=1.7
NAMESPACE=povsim
DEPLOYMENT=flights

DEFAULT_CYCLES=4
DEFAULT_QUIET_SECONDS=45

usage() {
    echo "Usage: $0 [-n instances] [-t target] [-e error_rate] [-u base_url] [-m max_minutes] [-r request_delay_secs] [-k] [-o] [-c cycles] [-q quiet_secs]"
    echo "  -n  Number of parallel loadgen instances per burst (default = ${DEFAULT_INSTANCES})"
    echo "  -t  Target environment: local (default) or orbstack -- passed through to flights-loadgen.sh"
    echo "  -e  Rate of requests that should error, expressed as a decimal in [0.0, 1.0] (default = ${DEFAULT_ERROR_RATE})"
    echo "  -u  Base URL of the service, overrides -t -- passed through to flights-loadgen.sh"
    echo "  -m  Safety cap in minutes (default = ${DEFAULT_MAX_MINUTES}). Without -o: give up after this long"
    echo "      with no crash. With -o: max time to wait for a crash PER CYCLE before giving up on it."
    echo "  -r  Per-request delay in seconds, passed through to flights-loadgen.sh -r"
    echo "      (default = ${DEFAULT_REQUEST_DELAY}, tuned for a ~5-10 min crash against a 256Mi limit --"
    echo "      lower this, e.g. -r 0.1, for a sharper/faster request-rate spike instead of a smooth ramp)"
    echo "  -k  Keep going after a crash is detected instead of stopping -- logs every restart and keeps"
    echo "      the SAME load running continuously for the full -m window (no gap, back-to-back crash-loop)."
    echo "      Without -k or -o, the script stops the instant it detects the first crash."
    echo "  -o  Oscillate mode: crash, STOP the load (pod goes back to normal), wait -q seconds, then launch"
    echo "      a fresh burst and crash it again -- repeated -c times. Use this for a demo that needs a"
    echo "      clean, repeating crash/recover/crash pattern instead of one continuous incident. Takes"
    echo "      precedence over -k if both are given."
    echo "  -c  Number of crash cycles to run in oscillate mode (default = ${DEFAULT_CYCLES}, only used with -o)"
    echo "  -q  Quiet period in seconds between a crash and the next burst in oscillate mode"
    echo "      (default = ${DEFAULT_QUIET_SECONDS}, only used with -o)"
    echo "  -h  Show this help message"
    exit 1
}

INSTANCES=$DEFAULT_INSTANCES
TARGET=$DEFAULT_TARGET
ERROR_RATE=$DEFAULT_ERROR_RATE
MAX_MINUTES=$DEFAULT_MAX_MINUTES
REQUEST_DELAY=$DEFAULT_REQUEST_DELAY
BASE_URL=""
KEEP_GOING=0
OSCILLATE=0
CYCLES=$DEFAULT_CYCLES
QUIET_SECONDS=$DEFAULT_QUIET_SECONDS

while getopts "n:t:e:u:m:r:koc:q:h" opt; do
    case $opt in
        n) INSTANCES="$OPTARG" ;;
        t) TARGET="$OPTARG" ;;
        e) ERROR_RATE="$OPTARG" ;;
        u) BASE_URL="$OPTARG" ;;
        m) MAX_MINUTES="$OPTARG" ;;
        r) REQUEST_DELAY="$OPTARG" ;;
        k) KEEP_GOING=1 ;;
        o) OSCILLATE=1 ;;
        c) CYCLES="$OPTARG" ;;
        q) QUIET_SECONDS="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ ! -x "$LOADGEN" ]; then
    echo "Error: $LOADGEN not found or not executable."
    echo "Run: chmod +x $LOADGEN"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found on PATH -- required to detect the crash."
    exit 1
fi

RUN_DURATION=$((MAX_MINUTES * 60))
LOADGEN_ARGS=(-t "$TARGET" -e "$ERROR_RATE" -d "$RUN_DURATION" -r "$REQUEST_DELAY")
if [ -n "$BASE_URL" ]; then
    LOADGEN_ARGS=(-b "$BASE_URL" -e "$ERROR_RATE" -d "$RUN_DURATION" -r "$REQUEST_DELAY")
fi

get_pod_and_restarts() {
    POD=$(kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    RESTARTS=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
}

get_pod_and_restarts
if [ -z "$POD" ]; then
    echo "Error: no running pod found for app=$DEPLOYMENT in namespace $NAMESPACE"
    exit 1
fi
BASELINE_POD="$POD"
BASELINE_RESTARTS="$RESTARTS"

PIDS=()
LOG_DIR=$(mktemp -d /tmp/flights-loadgen-parallel.XXXXXX)
START_TIME=$SECONDS

cleanup() {
    echo ""
    echo "Stopping ${#PIDS[@]} loadgen instance(s)..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    exit 130
}
trap cleanup INT TERM

if [ "$OSCILLATE" -eq 1 ]; then
    echo "----------------------------------------------------------"
    echo "Oscillate mode: crash -> quiet ${QUIET_SECONDS}s -> crash, x${CYCLES} cycles"
    echo "  pod:      $BASELINE_POD (restartCount=$BASELINE_RESTARTS)"
    echo "  target:   $TARGET${BASE_URL:+ (overridden by -u $BASE_URL)}"
    echo "  instances/burst: $INSTANCES, request delay: ${REQUEST_DELAY}s, error rate: $ERROR_RATE"
    echo "  per-cycle crash timeout: ${MAX_MINUTES} min"
    echo "  logs: $LOG_DIR/cycle-N-instance-M.log"
    echo "----------------------------------------------------------"

    OSCILLATE_CRASHES=0
    for CYCLE in $(seq 1 "$CYCLES"); do
        PIDS=()
        echo "--- cycle $CYCLE/$CYCLES: launching $INSTANCES instances (baseline restartCount=$BASELINE_RESTARTS) ---"
        for i in $(seq 1 "$INSTANCES"); do
            "$LOADGEN" "${LOADGEN_ARGS[@]}" > "$LOG_DIR/cycle-$CYCLE-instance-$i.log" 2>&1 &
            PIDS+=($!)
        done

        CYCLE_END=$((SECONDS + RUN_DURATION))
        CRASHED=0
        while [ $SECONDS -lt "$CYCLE_END" ]; do
            sleep 5
            get_pod_and_restarts
            if [ -n "$RESTARTS" ] && [ "$RESTARTS" != "$BASELINE_RESTARTS" ]; then
                OSCILLATE_CRASHES=$((OSCILLATE_CRASHES + 1))
                ELAPSED=$((SECONDS - START_TIME))
                echo "----------------------------------------------------------"
                echo "CRASH #${OSCILLATE_CRASHES} (cycle $CYCLE) at t+${ELAPSED}s -- pod $POD restartCount $BASELINE_RESTARTS -> $RESTARTS"
                kubectl describe pod -n "$NAMESPACE" "$POD" | sed -n '/State:/,/Ready:/p'
                echo "Stopping load for this cycle -- pod recovers during the ${QUIET_SECONDS}s quiet window."
                echo "----------------------------------------------------------"
                BASELINE_RESTARTS="$RESTARTS"
                CRASHED=1
                break
            fi
        done

        for pid in "${PIDS[@]}"; do
            kill "$pid" 2>/dev/null
        done
        wait "${PIDS[@]}" 2>/dev/null

        if [ "$CRASHED" -eq 0 ]; then
            echo "--- cycle $CYCLE/$CYCLES: no crash within ${MAX_MINUTES} min -- stopped load, moving on ---"
        fi

        if [ "$CYCLE" -lt "$CYCLES" ]; then
            echo "--- quiet period: ${QUIET_SECONDS}s with no load (pod back to normal) ---"
            sleep "$QUIET_SECONDS"
        fi
    done

    echo "----------------------------------------------------------"
    echo "Oscillate run complete: $OSCILLATE_CRASHES crash(es) across $CYCLES cycle(s)."
    echo "----------------------------------------------------------"
    if [ "$OSCILLATE_CRASHES" -gt 0 ]; then
        exit 0
    fi
    exit 1
fi

echo "----------------------------------------------------------"
echo "Slamming $DEPLOYMENT (namespace $NAMESPACE) until it crashes"
echo "  pod:      $BASELINE_POD (restartCount=$BASELINE_RESTARTS)"
echo "  target:   $TARGET${BASE_URL:+ (overridden by -u $BASE_URL)}"
echo "  instances: $INSTANCES, launched once, running continuously for up to ${MAX_MINUTES} min"
echo "  request delay: ${REQUEST_DELAY}s (paces aggregate throughput for consistent timing)"
echo "  error rate: $ERROR_RATE"
echo "  logs: $LOG_DIR/instance-N.log"
echo "----------------------------------------------------------"

for i in $(seq 1 "$INSTANCES"); do
    "$LOADGEN" "${LOADGEN_ARGS[@]}" > "$LOG_DIR/instance-$i.log" 2>&1 &
    PIDS+=($!)
done
echo "t+0s: launched ${#PIDS[@]} instances, running continuously (pids: ${PIDS[*]})"

# Poll for a crash every 5s for up to the full run duration -- no relaunching,
# no gaps in traffic. With -k, a crash is logged but the loadgen instances
# are left running (the pod restarts in place; curl calls just see a few
# failed/refused connections during the restart window and then succeed
# again once it's back up) so the pod can OOM repeatedly over the window.
CRASH_COUNT=0
END_TIME=$((SECONDS + RUN_DURATION))
while [ $SECONDS -lt "$END_TIME" ]; do
    sleep 5
    get_pod_and_restarts
    if [ -n "$RESTARTS" ] && [ "$RESTARTS" != "$BASELINE_RESTARTS" ]; then
        CRASH_COUNT=$((CRASH_COUNT + 1))
        ELAPSED=$((SECONDS - START_TIME))
        echo "----------------------------------------------------------"
        echo "CRASH #${CRASH_COUNT} DETECTED at t+${ELAPSED}s ($(( ELAPSED / 60 ))m$(( ELAPSED % 60 ))s) -- pod $POD restartCount $BASELINE_RESTARTS -> $RESTARTS"
        kubectl describe pod -n "$NAMESPACE" "$POD" | sed -n '/State:/,/Ready:/p'
        echo "----------------------------------------------------------"
        if [ "$KEEP_GOING" -eq 0 ]; then
            for pid in "${PIDS[@]}"; do
                kill "$pid" 2>/dev/null
            done
            exit 0
        fi
        # Keep going: adopt the new restart count as the baseline so the
        # next OOM (same pod, incremented again) is detected as a fresh
        # crash instead of re-triggering on the same count forever.
        BASELINE_RESTARTS="$RESTARTS"
    fi
done

echo "----------------------------------------------------------"
if [ "$CRASH_COUNT" -gt 0 ]; then
    echo "Reached the ${MAX_MINUTES} min cap after detecting $CRASH_COUNT crash(es) -- stopping load."
else
    echo "Gave up after ${MAX_MINUTES} min with no crash detected (pod is still healthy)."
    echo "Either raise -m, lower the memory limit, or check the pod is actually receiving traffic."
fi
echo "----------------------------------------------------------"
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null
done
if [ "$CRASH_COUNT" -gt 0 ]; then
    exit 0
fi
exit 1
