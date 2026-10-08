import logging
import os

import pyroscope
import requests
from flasgger import Swagger
from flask import Flask, jsonify, request
from flask_cors import CORS
from opentelemetry import trace
from opentelemetry.trace import SpanKind
from pythonjsonlogger import jsonlogger
from utils import get_random_int

_tracer = trace.get_tracer("flights.audit")
_app_logger = logging.getLogger("flights.app")
_AIRLINES_API_URL = os.environ.get(
    "AIRLINES_API_URL", "http://airlines.povsim.svc.cluster.local:8080/airlines"
)


class _JsonFormatter(jsonlogger.JsonFormatter):
    """Emit one JSON object per log line, promoting OTel-injected trace context
    fields to `trace_id`/`span_id` so Loki + Tempo can correlate on them.

    LoggingInstrumentor (enabled via OTEL_PYTHON_LOG_CORRELATION=true in the
    Dockerfile -- NOT OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED, which
    is a different, easily-confused flag that only controls handler setup)
    attaches `otelTraceID`, `otelSpanID`, and `otelTraceSampled`
    to every LogRecord. We rename them here so the field names match what
    Grafana Cloud's Tempo→Loki drilldown expects.
    """

    def add_fields(self, log_record, record, message_dict):
        super().add_fields(log_record, record, message_dict)
        otel_trace_id = getattr(record, "otelTraceID", None)
        otel_span_id = getattr(record, "otelSpanID", None)
        if otel_trace_id and otel_trace_id != "0":
            log_record["trace_id"] = otel_trace_id
        if otel_span_id and otel_span_id != "0":
            log_record["span_id"] = otel_span_id
        log_record.setdefault("level", record.levelname)
        log_record.setdefault("service.name", "flights")
        log_record.setdefault("env", "production")


_json_handler = logging.StreamHandler()
_json_handler.setFormatter(_JsonFormatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
_root = logging.getLogger()
_root.setLevel(logging.INFO)
# Replace any handlers Flask / opentelemetry-instrument installed so every
# log line hits stdout as JSON exactly once.
_root.handlers = [_json_handler]

# werkzeug's own per-request access log line ("GET /flights/AA 200") is
# emitted by BaseHTTPRequestHandler.handle_one_request() *after*
# run_wsgi() has already returned -- by which point OTel's WSGI
# instrumentation has already closed the request span. That line can
# therefore never carry real trace_id/span_id, no matter what else is
# fixed. Silencing it (ERROR still gets through, in case werkzeug ever
# logs a real server error) in favor of the after_request hook below,
# which logs the same information from *inside* the still-open span.
logging.getLogger("werkzeug").setLevel(logging.ERROR)

# pyroscope.configure()'s `tags` param is NOT auto-populated from
# PYROSCOPE_LABELS -- unlike the Java pyroscope agent (which reads that env
# var itself), the Python SDK requires it to be parsed and passed explicitly.
# Without this, setting PYROSCOPE_LABELS as a container env var is a no-op:
# confirmed live that airlines (Java) picked up namespace=povsim for free
# while flights did not, until this parsing was added.
_pyroscope_tags = dict(
    pair.split("=", 1)
    for pair in os.environ.get("PYROSCOPE_LABELS", "").split(",")
    if "=" in pair
)

pyroscope.configure(
    application_name=os.environ.get("PYROSCOPE_APPLICATION_NAME", "flights"),
    server_address=os.environ.get("PYROSCOPE_SERVER_ADDRESS", "http://pyroscope:4040"),
    basic_auth_username=os.environ.get("PYROSCOPE_BASIC_AUTH_USER"),
    basic_auth_password=os.environ.get("PYROSCOPE_BASIC_AUTH_PASSWORD"),
    tags=_pyroscope_tags,
    enable_logging=True,
)

app = Flask(__name__)
Swagger(app)
# allow_headers must explicitly list the W3C trace-context headers Faro's
# TracingInstrumentation injects (traceparent/tracestate) plus baggage --
# flask-cors's bare default does not echo these back in the CORS preflight
# response, so the browser silently drops them from the actual request. The
# GET/POST call still succeeds either way (that's why flights always shows
# up with its own span), but without this, that span is never linked to the
# frontend's span -- it lands as a lone, unstitched root span instead of
# part of a single frontend -> flights trace.
CORS(app, allow_headers=["Content-Type", "traceparent", "tracestate", "baggage"])


@app.after_request
def _log_access(response):
    # Replaces werkzeug's silenced access log (see logging.getLogger("werkzeug")
    # above). after_request hooks run inside Flask's own request dispatch,
    # which is inside the WSGI call that OTel's instrumentation wraps -- so
    # the span is still open here, unlike werkzeug's post-run_wsgi() logging.
    _app_logger.info("%s %s -> %s", request.method, request.path, response.status_code)
    return response

# BUG (staged intentionally): "activity log" for analytics with no eviction
# policy. Every flight search (GET /flights/<airline>) and booking
# (POST /flight) appends here and it's never trimmed, so memory grows
# monotonically with traffic -- a realistic unbounded-cache leak, not a
# synthetic allocator. Two different sizes because the two loadgens driving
# these endpoints have very different throughput:
#   - flights-loadgen.sh (curl, hits POST /flight) is fast -- 40KB/booking
#     is sized to stretch the crash out to ~5-10 min under the standard
#     10x-parallel trigger (verified live: 200KB/booking crossed a 128Mi
#     limit in ~114s; this is ~5x smaller for a proportionally ~5x longer
#     runway -- run flights-loadgen.sh with a duration comfortably longer
#     than that, e.g. -d 600, or the crash won't have sustained traffic to
#     finish the climb).
#   - frontend-loadgen.sh (k6 headless-browser clicks, hits GET
#     /flights/<airline> via the "Get Flights" button) is much slower --
#     each VU does a full page-load-and-click cycle, so 300KB/search
#     compensates for far fewer calls per minute (kept at the same ~5x
#     ratio to the booking size as before).
_booking_history = []


def _record_audit_event(payload_bytes, **span_attrs):
    """Mock call to an "audit/analytics service" -- there's no real network
    hop, this is just the in-memory leak (_booking_history.append), but it's
    wrapped in its own CLIENT-kind span so the trace waterfall shows *why*
    the request is slow/heavy instead of one flat request span. This is the
    literal spot causing the OOM: point at this span in the demo to connect
    "the trace says it wrote N bytes to audit-service" to "that's the leak."
    """
    with _tracer.start_as_current_span(
        "audit-service.record", kind=SpanKind.CLIENT
    ) as span:
        span.set_attribute("peer.service", "audit-service")
        span.set_attribute("audit.record_size_bytes", payload_bytes)
        for key, value in span_attrs.items():
            span.set_attribute(f"audit.{key}", value)
        _booking_history.append({"audit_payload": "x" * payload_bytes, **span_attrs})


def _fetch_operating_airlines():
    """Real HTTP call to the airlines service, checking which airlines are
    currently operating before returning a flight search. Unlike
    audit-service.record above, this is a genuine network hop -- requests'
    OTel auto-instrumentation creates a real CLIENT span here and propagates
    the traceparent header, and airlines' OTel Java agent auto-continues
    that trace as a SERVER span on its end. No manual span code needed; this
    is what actually stitches flights and airlines into one trace, since
    (per the call-graph research) nothing else in this repo ever calls
    airlines from flights or vice versa -- only the frontend calls both,
    independently.
    """
    resp = requests.get(_AIRLINES_API_URL, timeout=3)
    resp.raise_for_status()
    return [a.strip() for a in resp.text.split(",")]

@app.route('/health', methods=['GET'])
def health():
    """Health endpoint
    ---
    responses:
      200:
        description: Returns healthy
    """
    return jsonify({"status": "healthy"}), 200

@app.route("/", methods=['GET'])
def home():
    """No-op home endpoint
    ---
    responses:
      200:
        description: Returns ok
    """
    return jsonify({"message": "ok"}), 200

@app.route("/flights/<airline>", methods=["GET"])
def get_flights(airline):
    """Get flights endpoint. Optionally, set raise to trigger an exception.
    ---
    parameters:
      - name: airline
        in: path
        type: string
        enum: ["AA", "UA", "DL"]
        required: true
      - name: raise
        in: query
        type: str
        enum: ["500"]
        required: false
    responses:
      200:
        description: Returns a list of flights for the selected airline
    """
    status_code = request.args.get("raise")
    if status_code:
      raise Exception(f"Encountered {status_code} error") # pylint: disable=broad-exception-raised
    operating_airlines = _fetch_operating_airlines()
    random_int = get_random_int(100, 999)
    _record_audit_event(300_000, airline=airline, result=random_int)
    # Logged here -- while the request span is still active -- rather than
    # relying on werkzeug's own access log line. OTel's WSGI instrumentation
    # ends the span as soon as the response finishes streaming, but werkzeug
    # logs its "GET ... 200" access line AFTER that point (in
    # handle_one_request, once run_wsgi() has already returned), so that
    # line never has an active span to pull trace_id/span_id from -- this
    # explicit call is what actually gets trace context into a log line.
    _app_logger.info(
        "Searched flights for airline=%s (operating_airlines=%s)", airline, operating_airlines
    )
    return jsonify({airline: [random_int]}), 200

@app.route("/flight", methods=["POST"])
def book_flight():
    """Book flights endpoint. Optionally, set raise to trigger an exception.
    ---
    parameters:
      - name: passenger_name
        in: query
        type: string
        enum: ["John Doe", "Jane Doe"]
        required: true
      - name: flight_num
        in: query
        type: string
        enum: ["101", "202", "303", "404", "505", "606"]
        required: true
      - name: raise
        in: query
        type: str
        enum: ["500"]
        required: false
    responses:
      200:
        description: Booked a flight for the selected passenger and flight_num
    """
    status_code = request.args.get("raise")
    if status_code:
      raise Exception(f"Encountered {status_code} error") # pylint: disable=broad-exception-raised
    passenger_name = request.args.get("passenger_name")
    flight_num = request.args.get("flight_num")
    booking_id = get_random_int(100, 999)
    _record_audit_event(40_000, booking_id=booking_id, passenger_name=passenger_name, flight_num=flight_num)
    _app_logger.info("Booked flight_num=%s booking_id=%s", flight_num, booking_id)
    return jsonify({"passenger_name": passenger_name, "flight_num": flight_num, "booking_id": booking_id}), 200

if __name__ == "__main__":
    app.run(debug=True, port=5001)
