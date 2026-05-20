
# Step 1: Use an official Gradle image to build the application
FROM gradle:8.3.0-jdk17 AS build

WORKDIR /app
COPY . .
RUN gradle clean bootJar

# Step 2: Use a lightweight JDK image for running the app
FROM eclipse-temurin:17-jdk-jammy

WORKDIR /app

# Download the OpenTelemetry Java agent
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar

# Copy the JAR file from the build stage
COPY --from=build /app/build/libs/*.jar app.jar

# OpenTelemetry configuration
ENV OTEL_SERVICE_NAME="airlines"
ENV OTEL_RESOURCE_ATTRIBUTES="service.namespace=povsim"
ENV OTEL_EXPORTER_OTLP_ENDPOINT="http://grafana-k8s-monitoring-alloy-receiver.povsim.svc.cluster.local:4317"
ENV OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
ENV OTEL_METRICS_EXPORTER="otlp"
ENV OTEL_LOGS_EXPORTER="otlp"
ENV OTEL_TRACES_EXPORTER="otlp"

EXPOSE 8080

ENTRYPOINT ["java", "-javaagent:/app/opentelemetry-javaagent.jar", "-jar", "app.jar"]
