#!/usr/bin/env python3
"""Produce identifier-free JSON and Markdown evidence from a raw AWS experiment."""

import argparse
import json
from datetime import datetime
from pathlib import Path


TIMELINE = (
    ("Failure Injected", "failure_injected_at"),
    ("ALB Failure Detected", "alb_failure_detected_at"),
    ("ASG Replacement Started", "replacement_instance_observed_at"),
    ("Replacement Target Healthy", "replacement_target_healthy_at"),
    ("Capacity Recovery Complete", "final_capacity_convergence_at"),
)


def parse_time(value):
    if not value:
        return None
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")


def duration(start, end):
    left = parse_time(start)
    right = parse_time(end)
    return round((right - left).total_seconds(), 3) if left and right else None


def public_availability(raw):
    blocked_keys = {
        "serving_nodes_before_failure",
        "serving_nodes_after_convergence",
    }
    return {
        key: value for key, value in raw.get("availability", {}).items()
        if key not in blocked_keys
    }


def capacity_transitions(path):
    transitions = []
    previous = None
    if not path or not path.exists():
        return transitions
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        current = (
            row.get("phase"),
            row.get("desired_capacity"),
            row.get("inservice_instances"),
            row.get("healthy_targets"),
        )
        if current == previous:
            continue
        transitions.append({
            "timestamp": row.get("timestamp"),
            "phase": current[0],
            "desired_capacity": current[1],
            "inservice_instances": current[2],
            "healthy_targets": current[3],
        })
        previous = current
    return transitions


def curate(raw, status_path=None):
    timeline = raw.get("timeline", {})
    injected = timeline.get("failure_injected_at")
    events = [
        {"event": label, "timestamp": timeline.get(key)}
        for label, key in TIMELINE
        if timeline.get(key)
    ]
    curated = {
        "schema_version": "1.0",
        "evidence_class": "synthetic_mock" if raw.get("synthetic") else "curated_runtime",
        "synthetic": bool(raw.get("synthetic")),
        "scenario": raw.get("scenario"),
        "outcome": raw.get("recovery", {}).get("outcome"),
        "timeline": events,
        "durations_seconds": {
            "failure_detection": duration(injected, timeline.get("alb_failure_detected_at")),
            "replacement_observed": duration(injected, timeline.get("replacement_instance_observed_at")),
            "replacement_healthy": duration(injected, timeline.get("replacement_target_healthy_at")),
            "total_convergence": raw.get("recovery", {}).get("total_duration_seconds"),
        },
        "availability": public_availability(raw),
        "capacity_before": raw.get("pre_failure", {}),
        "capacity_after": raw.get("post_recovery", {}),
        "capacity_transitions": capacity_transitions(status_path),
        "failure_reason": raw.get("failure_reason"),
        "redaction": {
            "account_id": "removed",
            "instance_ids": "removed",
            "ip_addresses": "removed",
            "load_balancer_dns": "removed",
            "arns": "removed",
        },
    }
    return curated


def markdown(curated):
    availability = curated["availability"]
    durations = curated["durations_seconds"]
    warning = "**SYNTHETIC MOCK — NOT AWS RUNTIME EVIDENCE**\n\n" if curated["synthetic"] else ""
    timeline = " → ".join(event["event"] for event in curated["timeline"])
    return """# AWS Web Host Loss evidence

{warning}{timeline}

## Key results

- HTTP requests: {total} total / {success} successful / {failed} failed
- Failure-window error rate: {error_rate}%
- Maximum unavailable window: {unavailable}s
- Failure detection: {detection}s
- Replacement target healthy: {healthy}s
- Total capacity convergence: {convergence}s

## Capacity

- Before: ASG {before_inservice}/{before_desired}, ALB healthy {before_healthy}
- After: ASG {after_inservice}/{after_desired}, ALB healthy {after_healthy}

Identifiers are removed from this curated document. Raw evidence remains Git-ignored.
""".format(
        warning=warning,
        timeline=timeline,
        total=availability.get("total_requests"),
        success=availability.get("successful_requests"),
        failed=availability.get("failed_requests"),
        error_rate=availability.get("failure_window_error_rate_percent"),
        unavailable=availability.get("max_unavailable_duration_seconds"),
        detection=durations.get("failure_detection"),
        healthy=durations.get("replacement_healthy"),
        convergence=durations.get("total_convergence"),
        before_inservice=curated["capacity_before"].get("inservice_instances"),
        before_desired=curated["capacity_before"].get("desired_capacity"),
        before_healthy=curated["capacity_before"].get("healthy_targets"),
        after_inservice=curated["capacity_after"].get("inservice_instances"),
        after_desired=curated["capacity_after"].get("desired_capacity"),
        after_healthy=curated["capacity_after"].get("healthy_targets"),
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("--status", type=Path)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--markdown-output", type=Path, required=True)
    args = parser.parse_args()
    raw = json.loads(args.raw.read_text(encoding="utf-8"))
    curated = curate(raw, args.status)
    args.json_output.write_text(json.dumps(curated, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.markdown_output.write_text(markdown(curated), encoding="utf-8")


if __name__ == "__main__":
    main()
