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
ENV OTEL_RESOURCE_ATTRIBUTES="service.namespace=povsim,env=production"
ENV OTEL_EXPORTER_OTLP_ENDPOINT="http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4318"
ENV OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
ENV OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
# OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED (above) only controls
# whether opentelemetry-instrumentation-logging skips installing its handler
# in favor of the SDK's deprecated one -- it does NOT inject trace context
# into log records. That's a separate, easily-confused flag:
# OTEL_PYTHON_LOG_CORRELATION is what actually makes the patched
# LogRecordFactory set otelTraceID/otelSpanID on records created while a
# span is active. Without this, _JsonFormatter's getattr(record,
# "otelTraceID", None) always returns None and no log line ever carries
# trace_id/span_id, no matter where in the request lifecycle it's logged.
ENV OTEL_PYTHON_LOG_CORRELATION=true
# Logs are emitted as structured JSON to stdout (see app.py's _JsonFormatter)
# and captured by Alloy's filelog receiver. Disabling the OTel SDK's OTLP log
# exporter prevents every log line from being shipped twice.
ENV OTEL_LOGS_EXPORTER=none
ENV OTEL_METRICS_EXPORTER=otlp
ENV OTEL_TRACES_EXPORTER=otlp

EXPOSE 5001

# --with-threads: Werkzeug's dev server is single-threaded by default, so it
# processes exactly one request at a time regardless of how much concurrent
# load is thrown at it from the client side -- that serial bottleneck (not
# the loadgen) is what was capping observed throughput at ~8 req/s. Threaded
# mode lets it actually handle concurrent requests, which is required to see
# a real request-rate spike under parallel load.
CMD ["opentelemetry-instrument", "flask", "run", "--host=0.0.0.0", "--port=5001", "--with-threads"]
