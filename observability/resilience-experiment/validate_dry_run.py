#!/usr/bin/env python3
"""Validate that the provisioned dashboard can query a complete synthetic timeline."""

import argparse
import json
import time
from urllib.parse import urlencode
from urllib.request import urlopen


REQUIRED_METRICS = {
    "p1_http_probe_success",
    "p1_http_availability_percent",
    "p1_http_error_rate_percent",
    "p1_alb_healthy_targets",
    "p1_asg_inservice_instances",
    "p1_asg_desired_capacity",
    "p1_experiment_phase",
    "p1_event_reached",
    "p1_recovery_duration_seconds",
    "p1_synthetic_evidence",
}


def get_json(url):
    with urlopen(url, timeout=5) as response:
        return json.load(response)


def query_range(prometheus_url, expression, start, end):
    query = urlencode({"query": expression, "start": start, "end": end, "step": 1})
    document = get_json("{}/api/v1/query_range?{}".format(prometheus_url, query))
    if document.get("status") != "success":
        raise AssertionError("Prometheus query failed: {}".format(expression))
    return document["data"]["result"]


def flattened_values(series):
    return [float(value) for item in series for _, value in item.get("values", [])]


def dashboard_metrics(dashboard):
    metrics = set()
    for panel in dashboard.get("panels", []):
        for target in panel.get("targets", []):
            expression = target.get("expr")
            if expression:
                metrics.add(expression)
    return metrics


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--grafana-url", default="http://127.0.0.1:33000")
    parser.add_argument("--prometheus-url", default="http://127.0.0.1:39090")
    args = parser.parse_args()

    health = get_json(args.grafana_url + "/api/health")
    if health.get("database") != "ok":
        raise AssertionError("Grafana is not healthy")
    dashboard = get_json(args.grafana_url + "/api/dashboards/uid/p01-resilience")["dashboard"]
    missing = REQUIRED_METRICS - dashboard_metrics(dashboard)
    if missing:
        raise AssertionError("Dashboard misses metrics: {}".format(sorted(missing)))

    end = int(time.time())
    start = end - 90
    results = {}
    for metric in sorted(REQUIRED_METRICS):
        results[metric] = query_range(args.prometheus_url, metric, start, end)
        if not results[metric]:
            raise AssertionError("No data for panel metric: {}".format(metric))

    expected_transitions = {
        "p1_http_probe_success": {0.0, 1.0},
        "p1_alb_healthy_targets": {1.0, 2.0},
        "p1_asg_inservice_instances": {1.0, 2.0},
    }
    for metric, expected in expected_transitions.items():
        observed = set(flattened_values(results[metric]))
        if not expected <= observed:
            raise AssertionError("{} lacks transitions {}; got {}".format(metric, expected, observed))

    phases = set(flattened_values(results["p1_experiment_phase"]))
    if not {0.0, 1.0, 2.0, 3.0, 4.0, 5.0} <= phases:
        raise AssertionError("Experiment phases are incomplete: {}".format(phases))

    synthetic = results["p1_synthetic_evidence"]
    if 1.0 not in set(flattened_values(synthetic)):
        raise AssertionError("Dry run is not explicitly marked synthetic")

    event_series = query_range(args.prometheus_url, "p1_event_timestamp_seconds", start, end)
    latest_events = {
        item["metric"].get("event"): float(item["values"][-1][1])
        for item in event_series if item.get("values")
    }
    ordered = [
        latest_events.get(name, 0)
        for name in (
            "failure_injected",
            "failure_detected",
            "replacement_started",
            "replacement_healthy",
            "recovery_complete",
        )
    ]
    if not all(value > 0 for value in ordered) or ordered != sorted(ordered):
        raise AssertionError("Event timestamps are absent or misaligned: {}".format(ordered))

    print(json.dumps({
        "dashboard": dashboard["title"],
        "panel_metric_count": len(REQUIRED_METRICS),
        "timeline_aligned": True,
        "failure_interval_visible": True,
        "recovery_visible": True,
        "synthetic": True,
    }, sort_keys=True))


if __name__ == "__main__":
    main()
