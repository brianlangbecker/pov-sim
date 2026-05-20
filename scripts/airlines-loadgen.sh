#!/bin/bash

# USAGE
#
# This script allows you to make batch requests to the airlines service
#
# Note: You may need to run `chmod +x airlines-loadgen.sh` in order to execute the script
#
# To run the script:
# ./airlines-loadgen.sh
#
# Target OrbStack:
# ./airlines-loadgen.sh -t orbstack
#
# Specify a 25% error rate, 30 sec duration, and base URL:
# ./airlines-loadgen.sh -e 0.25 -d 30 -b http://localhost:8081
#
# Run help command to see details and usage options:
# ./airlines-loadgen.sh -h

LINE_SEPARATOR="----------------------------------------------------------"

DEFAULT_ERROR_RATE=0
DEFAULT_DURATION=60
LOCAL_BASE_URL="http://localhost:8080"
ORBSTACK_BASE_URL="http://airlines.povsim.svc.cluster.local:8080"
DEFAULT_BASE_URL=$LOCAL_BASE_URL

BASIC_GET_ENDPOINTS=(
    "/"
    "/health"
)
GET_AIRLINES_ENDPOINT="/airlines"
GET_AIRLINES_RAISE_QUERY_PARAM="?raise=true"

usage() {
    echo "Usage: $0 [-t target] [-e error_rate] [-d duration_secs] [-b base_url]"
    echo "  -t  Target environment: local (default) or orbstack"
    echo "  -e  Rate of requests that should error, expressed as a decimal in the range [0.0, 1.0] (default = ${DEFAULT_ERROR_RATE})"
    echo "  -d  Duration of the test in seconds (default = ${DEFAULT_DURATION})"
    echo "  -b  Base URL of the service, overrides -t (default = ${DEFAULT_BASE_URL})"
    echo "  -h  Show this help message"
    exit 1
}

ERROR_RATE=$DEFAULT_ERROR_RATE
DURATION=$DEFAULT_DURATION
BASE_URL=$DEFAULT_BASE_URL

while getopts "t:e:d:b:h" opt; do
    case $opt in
        t)
            case "$OPTARG" in
                local)    BASE_URL=$LOCAL_BASE_URL ;;
                orbstack) BASE_URL=$ORBSTACK_BASE_URL ;;
                *) echo "Unknown target: $OPTARG. Use 'local' or 'orbstack'."; exit 1 ;;
            esac
            ;;
        e) ERROR_RATE="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        b) BASE_URL="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if (( $(echo "$ERROR_RATE < 0.0" | bc -l) )) || (( $(echo "$ERROR_RATE > 1.0" | bc -g) )); then
    echo "Error: Error rate must be in the range [0.0, 1.0]"
    echo "Exiting..."
    exit 1
fi

run_loadgen() {
    echo $LINE_SEPARATOR
    echo "⏳ Starting loadgen for $DURATION seconds with error rate of $ERROR_RATE ⏳"
    echo $LINE_SEPARATOR

    START_TIME=$(date +%s)

    while true; do
        # Loop until elapsed time exceeds target duration
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$(($CURRENT_TIME - $START_TIME))
        if (( $(echo "$ELAPSED_TIME > $DURATION" | bc -l) )); then
            break
        fi

        # Ping basic GET endpoints
        for i in "${BASIC_GET_ENDPOINTS[@]}"; do
            ENDPOINT="$BASE_URL$i"
            echo "\nSending GET request: $ENDPOINT..."
            curl $ENDPOINT
            echo "\n"
        done

        # Ping GET airlines
        # Invoke error per error rate
        QUERY_PARAMS=""
        RAND_DEC=($echo "0.$((RANDOM % 100))")
        if (( $(echo "$RAND_DEC < $ERROR_RATE" | bc -l) )); then
            QUERY_PARAMS=$GET_AIRLINES_RAISE_QUERY_PARAM
        fi
        ENDPOINT="$BASE_URL$GET_AIRLINES_ENDPOINT$QUERY_PARAMS"
        echo "\nSending GET request: $ENDPOINT"
        curl $ENDPOINT
        echo "\n"

        sleep 1
    done

    echo $LINE_SEPARATOR
    echo "✅ Completed loadgen for $DURATION seconds with error rate of $ERROR_RATE ✅"
    echo $LINE_SEPARATOR
}

run_loadgen
