# 🚀 PoV Flight Simulator — OrbStack + Helm 🚀

Welcome to the PoV Flight Simulator (OrbStack + Helm edition)

- [About](#about)
- [Getting Up and Running](#getting-up-and-running)
  - [Prerequisites](#prerequisites)
  - [Deploy all services](#deploy-all-services)
- [Install Grafana k8s Monitoring](#install-grafana-k8s-monitoring)
- [Simulate traffic to the services](#simulate-traffic-to-the-services)
  - [airlines-loadgen](#running-airlines-loadgen)
  - [flights-loadgen](#running-flights-loadgen)

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

## Deploy all services

From the project root, build the Docker images:
```
docker build -t pov-sim-airlines:latest ./airlines
docker build -t pov-sim-flights:latest ./flights
docker build \
  --build-arg REACT_APP_AIRLINES_API_URL=http://airlines.povsim.svc.cluster.local:8080/airlines \
  --build-arg REACT_APP_FLIGHTS_API_URL=http://flights.povsim.svc.cluster.local:5001/flights \
  -t pov-sim-frontend:latest ./frontend
```

Deploy all services with the following command:
```
helm upgrade --install pov-sim ./helm-charts/pov-sim
```

- *The `airlines` service will run on http://airlines.povsim.svc.cluster.local:8080/ with Swagger doc UI at http://airlines.povsim.svc.cluster.local:8080/swagger-ui/index.html#/*
- *The `flights` service will run on http://flights.povsim.svc.cluster.local:5001/ with Swagger doc UI at http://flights.povsim.svc.cluster.local:5001/apidocs/*
- *The `frontend` service will run on http://frontend.povsim.svc.cluster.local:3000/*

Confirm all pods are running:
```
kubectl get pods
```

Tear down all services with the following command:
```
helm uninstall pov-sim
```

# Install Alloy for Kubernetes

This repo includes a pre-configured values file for the [Grafana k8s Monitoring](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/) Helm chart that ships telemetry (metrics, logs, traces, profiles) to Grafana Cloud.

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

Confirm the collectors are running:
```
kubectl get pods -n povsim | grep alloy
```

Once installed, configure your applications to send telemetry to the following endpoints:

| Protocol | Endpoint |
| :---: | :---: |
| OTLP gRPC | `http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4317` |
| OTLP HTTP | `http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4318` |
| Zipkin | `http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:9411` |

# Simulate traffic to the services

The `scripts/` directory includes load generator scripts you can use to make batch sets of requests to your running services.

- The `airlines-loadgen.sh` script generates load to the `airlines` service
- The `flights-loadgen.sh` script generates load to the `flights` service

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
