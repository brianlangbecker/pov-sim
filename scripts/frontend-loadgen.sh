#!/bin/bash

# USAGE
#
# This script drives a k6 browser-based load generator against the
# `frontend` service. Unlike the airlines/flights loadgens (which use
# curl and never load the React bundle), this spins up a real headless
# Chromium so Faro RUM events fire and frontend → airlines → flights
# traces are produced end-to-end.
#
# Requires: k6 v0.46+ (the k6/browser module is built in). Install:
#   brew install k6
#   # or see https://k6.io/docs/get-started/installation/
#
# Note: You may need to run `chmod +x frontend-loadgen.sh` in order to
# execute the script.
#
# To run the script:
# ./frontend-loadgen.sh
#
# Target OrbStack:
# ./frontend-loadgen.sh -t orbstack
#
# Run 4 parallel browsers for 5 minutes against OrbStack:
# ./frontend-loadgen.sh -t orbstack -v 4 -d 300
#
# Run help command to see details and usage options:
# ./frontend-loadgen.sh -h

LINE_SEPARATOR="----------------------------------------------------------"

DEFAULT_TARGET=local
DEFAULT_DURATION=60
DEFAULT_VUS=2

usage() {
    echo "Usage: $0 [-t target] [-v vus] [-d duration_secs]"
    echo "  -t  Target environment: local (default) or orbstack"
    echo "  -v  Number of parallel browsers / virtual users (default = ${DEFAULT_VUS})"
    echo "  -d  Duration in seconds (default = ${DEFAULT_DURATION})"
    echo "  -h  Show this help message"
    exit 1
}

TARGET=$DEFAULT_TARGET
DURATION=$DEFAULT_DURATION
VUS=$DEFAULT_VUS

while getopts "t:v:d:h" opt; do
    case $opt in
        t)
            case "$OPTARG" in
                local|orbstack) TARGET="$OPTARG" ;;
                *) echo "Unknown target: $OPTARG. Use 'local' or 'orbstack'."; exit 1 ;;
            esac
            ;;
        v) VUS="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if ! command -v k6 >/dev/null 2>&1; then
    echo "Error: k6 not found on PATH."
    echo "Install via 'brew install k6' or see https://k6.io/docs/get-started/installation/"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo $LINE_SEPARATOR
echo "⏳ Starting frontend loadgen — target=$TARGET, VUs=$VUS, duration=${DURATION}s ⏳"
echo $LINE_SEPARATOR

k6 run \
    -e TARGET="$TARGET" \
    -e DURATION="${DURATION}s" \
    -e VUS="$VUS" \
    "$SCRIPT_DIR/frontend-loadgen.js"

EXIT_CODE=$?

echo $LINE_SEPARATOR
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Completed frontend loadgen — target=$TARGET, VUs=$VUS, duration=${DURATION}s ✅"
else
    echo "❌ Frontend loadgen exited with code $EXIT_CODE"
fi
echo $LINE_SEPARATOR

exit $EXIT_CODE
