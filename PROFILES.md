# Continuous Profiling (Pyroscope) Setup

Both `airlines` and `flights` ship CPU profiles to Grafana Cloud Pyroscope.
This complements the system-wide eBPF profiling already running via the
`alloy-profiles` DaemonSet (see `alloy/CONFIG.md`) — the in-process agents
give higher-fidelity, app-labeled flame graphs.

## Common configuration

| Setting | Value |
|---|---|
| Endpoint | `https://profiles-prod-026.grafana.net:443` |
| Auth | HTTP Basic, sourced from K8s Secret `grafana-cloud-profiles-grafana-k8s-monitoring` |
| Secret origin | Created by the `grafana-k8s-monitoring` Helm chart at install time |

Both deployments expose the same four env vars to their pod:

```yaml
- name: PYROSCOPE_APPLICATION_NAME       # "airlines" or "flights"
- name: PYROSCOPE_SERVER_ADDRESS         # https://profiles-prod-026.grafana.net:443
- name: PYROSCOPE_BASIC_AUTH_USER        # from secret key "username"
- name: PYROSCOPE_BASIC_AUTH_PASSWORD    # from secret key "password"
```

## airlines (Java, Spring Boot) — `-javaagent` mode

Zero application code change. The Dockerfile downloads the Pyroscope Java
agent jar and adds it as a JVM `-javaagent` alongside the OTel agent:

```dockerfile
ADD https://github.com/grafana/pyroscope-java/releases/download/v2.1.2/pyroscope.jar /app/pyroscope.jar
...
ENTRYPOINT ["java",
            "-javaagent:/app/opentelemetry-javaagent.jar",
            "-javaagent:/app/pyroscope.jar",
            "-jar", "app.jar"]
```

The agent reads all of its config from the env vars on the pod — nothing
in `Application.java` knows about Pyroscope.

**Verifying:** pod logs show `[INFO] Profiling started` and a config dump
with `applicationName='airlines'` and `serverAddress='https://...'`.

## flights (Python, Flask) — SDK mode

Python has no `-javaagent` equivalent. Minimal SDK initialization at the
top of `app.py`:

```python
import pyroscope
pyroscope.configure(
    application_name=os.environ.get("PYROSCOPE_APPLICATION_NAME", "flights"),
    server_address=os.environ.get("PYROSCOPE_SERVER_ADDRESS", "http://pyroscope:4040"),
    basic_auth_username=os.environ.get("PYROSCOPE_BASIC_AUTH_USER"),
    basic_auth_password=os.environ.get("PYROSCOPE_BASIC_AUTH_PASSWORD"),
    enable_logging=True,
)
```

### Critical: pyroscope-io version matters with Python 3.12

`pyroscope-io 0.8.7` (and earlier 0.8.x) **does not work with Python 3.12**.
Its bundled `py-spy` fails to attach to the interpreter with:

```
py_spy::python_spy > Failed to connect to process, retrying.
                     Error: Unsupported version of Python: 3.12.0
```

The Pyroscope agent thread starts, but `py-spy` retries forever and no
frames are ever uploaded. From the outside this looks like "configure
returned cleanly but nothing shows in the UI."

Use `pyroscope-io >= 1.0.11`, which ships `cp310-abi3` wheels (Python's
stable ABI) — these work on Python 3.10, 3.11, 3.12, and 3.13 without
recompilation.

```
flights/requirements.txt:
  pyroscope-io==1.0.11
```

**Verifying:** the 1.0.x SDK is quiet by default. The most reliable signal
is an outbound HTTPS connection to port 443 from PID 1:

```bash
kubectl exec -n povsim <flights-pod> -- \
  awk 'NR>1 && $4=="01" {print $2,$3}' /proc/1/net/tcp6 /proc/1/net/tcp
# Expect to see an ESTABLISHED line containing :01BB (= port 443)
```

## End-to-end check

```bash
# Generate load to make the flame graphs interesting
./scripts/airlines-loadgen.sh -t orbstack -e 0.25 -d 300 & \
./scripts/flights-loadgen.sh  -t orbstack -e 0.25 -d 300 & \
wait
```

Then in Grafana Cloud: Explore → Pyroscope datasource → filter by
`service_name="airlines"` or `service_name="flights"`. Profiles appear
within one upload interval (~10s).
