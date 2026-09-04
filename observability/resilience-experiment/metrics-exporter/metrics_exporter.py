#!/usr/bin/env python3
"""Expose the current experiment state and probe log as Prometheus metrics."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn


PHASE_CODES = {
    "waiting": -1,
    "baseline": 0,
    "failure_injected": 1,
    "degraded": 2,
    "replacement_started": 3,
    "replacement_healthy": 4,
    "recovered": 5,
    "failed": 6,
}
EVENTS = (
    "failure_injected",
    "failure_detected",
    "replacement_started",
    "replacement_healthy",
    "recovery_complete",
)


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def _escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def read_state(path):
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {
            "phase": "waiting",
            "desired_capacity": 0,
            "inservice_instances": 0,
            "healthy_targets": 0,
            "events": {},
        }


def read_probes(state_path, state):
    probe_name = state.get("probe_file")
    if not probe_name or Path(probe_name).name != probe_name:
        return []
    probe_path = state_path.parent / probe_name
    samples = []
    try:
        with probe_path.open(encoding="utf-8") as stream:
            for line in stream:
                parts = line.rstrip("\n").split("\t", 3)
                if len(parts) != 4:
                    continue
                samples.append({
                    "epoch_ms": int(parts[0]),
                    "success": parts[2] == "1",
                })
    except (FileNotFoundError, OSError, ValueError):
        return []
    return samples


def render_metrics(state_path):
    state = read_state(state_path)
    probes = read_probes(state_path, state)
    total = len(probes)
    successes = sum(1 for sample in probes if sample["success"])
    failures = total - successes
    availability = successes / total * 100.0 if total else 0.0
    error_rate = failures / total * 100.0 if total else 0.0
    latest_success = 1 if probes and probes[-1]["success"] else 0
    phase = state.get("phase", "waiting")
    events = state.get("events", {})

    metrics = [
        "# HELP p1_http_probe_success Latest HTTP probe outcome (1 success, 0 failure).",
        "# TYPE p1_http_probe_success gauge",
        "p1_http_probe_success {}".format(latest_success),
        "# HELP p1_http_availability_percent Cumulative HTTP availability for this experiment.",
        "# TYPE p1_http_availability_percent gauge",
        "p1_http_availability_percent {:.6f}".format(availability),
        "# HELP p1_http_error_rate_percent Cumulative HTTP error rate for this experiment.",
        "# TYPE p1_http_error_rate_percent gauge",
        "p1_http_error_rate_percent {:.6f}".format(error_rate),
        "# TYPE p1_http_requests_total gauge",
        "p1_http_requests_total {}".format(total),
        "# TYPE p1_http_requests_successful gauge",
        "p1_http_requests_successful {}".format(successes),
        "# TYPE p1_http_requests_failed gauge",
        "p1_http_requests_failed {}".format(failures),
        "# HELP p1_alb_healthy_targets Healthy ALB target count from AWS API polling.",
        "# TYPE p1_alb_healthy_targets gauge",
        "p1_alb_healthy_targets {}".format(int(state.get("healthy_targets", 0))),
        "# HELP p1_asg_inservice_instances InService and healthy ASG instance count.",
        "# TYPE p1_asg_inservice_instances gauge",
        "p1_asg_inservice_instances {}".format(int(state.get("inservice_instances", 0))),
        "# HELP p1_asg_desired_capacity ASG desired capacity.",
        "# TYPE p1_asg_desired_capacity gauge",
        "p1_asg_desired_capacity {}".format(int(state.get("desired_capacity", 0))),
        "# HELP p1_experiment_phase Ordered experiment phase code.",
        "# TYPE p1_experiment_phase gauge",
        'p1_experiment_phase{{phase="{}"}} {}'.format(_escape(phase), PHASE_CODES.get(phase, -1)),
        "# HELP p1_recovery_duration_seconds Measured injection-to-convergence duration.",
        "# TYPE p1_recovery_duration_seconds gauge",
        "p1_recovery_duration_seconds {}".format(float(state.get("recovery_duration_seconds", 0))),
        "# HELP p1_synthetic_evidence Whether the current feed is synthetic mock data.",
        "# TYPE p1_synthetic_evidence gauge",
        "p1_synthetic_evidence {}".format(1 if state.get("synthetic") else 0),
        "# HELP p1_event_reached Whether a resilience event has occurred.",
        "# TYPE p1_event_reached gauge",
        "# HELP p1_event_timestamp_seconds Exact event time as Unix seconds.",
        "# TYPE p1_event_timestamp_seconds gauge",
    ]
    for event in EVENTS:
        timestamp = float(events.get(event, 0) or 0)
        metrics.append('p1_event_reached{{event="{}"}} {}'.format(event, 1 if timestamp else 0))
        metrics.append('p1_event_timestamp_seconds{{event="{}"}} {}'.format(event, timestamp))
    return "\n".join(metrics) + "\n"


def handler_factory(state_path):
    class MetricsHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                body = b"ok\n"
                status = 200
                content_type = "text/plain"
            elif self.path == "/metrics":
                body = render_metrics(state_path).encode("utf-8")
                status = 200
                content_type = "text/plain; version=0.0.4"
            else:
                body = b"not found\n"
                status = 404
                content_type = "text/plain"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format, *_args):
            return

    return MetricsHandler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9108)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.listen, args.port), handler_factory(args.state))
    server.serve_forever()


if __name__ == "__main__":
    main()
