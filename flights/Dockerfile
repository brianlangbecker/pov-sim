FROM python:3.12-slim

WORKDIR /python-docker

COPY requirements.txt requirements.txt

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# renovate: datasource=pypi depName=opentelemetry-distro
ENV OPENTELEMETRY_DISTRO_VERSION=0.62b1
RUN pip install --no-cache-dir "opentelemetry-distro[otlp]==$OPENTELEMETRY_DISTRO_VERSION" && \
    opentelemetry-bootstrap -a install

COPY . .

ENV OTEL_SERVICE_NAME="flights"
ENV OTEL_RESOURCE_ATTRIBUTES="service.namespace=povsim"
ENV OTEL_EXPORTER_OTLP_ENDPOINT="http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4318"
ENV OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
ENV OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
ENV OTEL_LOGS_EXPORTER=otlp
ENV OTEL_METRICS_EXPORTER=otlp
ENV OTEL_TRACES_EXPORTER=otlp

EXPOSE 5001

CMD ["opentelemetry-instrument", "flask", "run", "--host=0.0.0.0", "--port=5001"]
