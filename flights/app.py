import logging
import os

import pyroscope
from flasgger import Swagger
from flask import Flask, jsonify, request
from flask_cors import CORS
from pythonjsonlogger import jsonlogger
from utils import get_random_int


class _JsonFormatter(jsonlogger.JsonFormatter):
    """Emit one JSON object per log line, promoting OTel-injected trace context
    fields to `trace_id`/`span_id` so Loki + Tempo can correlate on them.

    LoggingInstrumentor (enabled via OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
    in the Dockerfile) attaches `otelTraceID`, `otelSpanID`, and `otelTraceSampled`
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

pyroscope.configure(
    application_name=os.environ.get("PYROSCOPE_APPLICATION_NAME", "flights"),
    server_address=os.environ.get("PYROSCOPE_SERVER_ADDRESS", "http://pyroscope:4040"),
    basic_auth_username=os.environ.get("PYROSCOPE_BASIC_AUTH_USER"),
    basic_auth_password=os.environ.get("PYROSCOPE_BASIC_AUTH_PASSWORD"),
    enable_logging=True,
)

app = Flask(__name__)
Swagger(app)
CORS(app)

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
    random_int = get_random_int(100, 999)
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
    return jsonify({"passenger_name": passenger_name, "flight_num": flight_num, "booking_id": booking_id}), 200

if __name__ == "__main__":
    app.run(debug=True, port=5001)
