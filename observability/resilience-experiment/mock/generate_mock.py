#!/usr/bin/env python3
"""Generate a clearly synthetic host-loss timeline for the local dashboard."""

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path


def iso_from_ms(epoch_ms):
    return datetime.fromtimestamp(epoch_ms / 1000.0, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def write_json_atomic(path, document):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def phase_at(tick):
    if tick < 6:
        return "baseline"
    if tick == 6:
        return "failure_injected"
    if tick < 10:
        return "degraded"
    if tick < 18:
        return "replacement_started"
    if tick < 20:
        return "replacement_healthy"
    return "recovered"


def capacity_at(tick):
    if tick < 6:
        return 2, 2
    if tick < 18:
        return 1, 1
    return 2, 2


def probe_outcomes(tick):
    if tick == 6:
        return (True, False, True, False)
    if tick == 7:
        return (True, True, False, True)
    return (True, True, True, True)


def summarize_probe_file(path, failure_ms, convergence_ms):
    samples = []
    for line in path.read_text(encoding="utf-8").splitlines():
        epoch_ms, _timestamp, success, _node = line.split("\t", 3)
        samples.append((int(epoch_ms), success == "1"))
    window = [sample for sample in samples if failure_ms <= sample[0] <= convergence_ms]
    failures = sum(1 for _, success in samples if not success)
    window_failures = sum(1 for _, success in window if not success)
    max_run = 0
    current_run = 0
    for _, success in window:
        current_run = 0 if success else current_run + 1
        max_run = max(max_run, current_run)
    return {
        "probe_interval_ms": 250,
        "total_requests": len(samples),
        "successful_requests": len(samples) - failures,
        "failed_requests": failures,
        "failure_window_requests": len(window),
        "failure_window_failed_requests": window_failures,
        "failure_window_error_rate_percent": round(window_failures / len(window) * 100.0, 3),
        "max_consecutive_failures": max_run,
        "max_unavailable_duration_seconds": round(max_run * 0.25, 3),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--tick-seconds", type=float, default=1.0)
    args = parser.parse_args()
    args.artifact_dir.mkdir(parents=True, exist_ok=True)

    state_path = args.artifact_dir / "live-state.json"
    probe_path = args.artifact_dir / "mock-probes.tsv"
    status_path = args.artifact_dir / "mock-aws-status.jsonl"
    raw_path = args.artifact_dir / "mock-raw-evidence.json"
    probe_path.write_text("", encoding="utf-8")
    status_path.write_text("", encoding="utf-8")

    start_ms = int(time.time() * 1000)
    event_ticks = {
        "failure_injected": 6,
        "failure_detected": 7,
        "replacement_started": 10,
        "replacement_healthy": 18,
        "recovery_complete": 20,
    }
    event_ms = {name: start_ms + tick * 1000 for name, tick in event_ticks.items()}

    for tick in range(25):
        tick_ms = start_ms + tick * 1000
        with probe_path.open("a", encoding="utf-8") as stream:
            for offset, success in enumerate(probe_outcomes(tick)):
                sample_ms = tick_ms + offset * 250
                stream.write("{}\t{}\t{}\tsynthetic-node\n".format(
                    sample_ms, iso_from_ms(sample_ms), 1 if success else 0
                ))

        inservice, healthy = capacity_at(tick)
        events = {
            name: event_ms[name] / 1000.0
            for name, event_tick in event_ticks.items()
            if tick >= event_tick
        }
        state = {
            "schema_version": "1.0",
            "synthetic": True,
            "phase": phase_at(tick),
            "probe_file": probe_path.name,
            "desired_capacity": 2,
            "inservice_instances": inservice,
            "healthy_targets": healthy,
            "events": events,
            "recovery_duration_seconds": 14.0 if tick >= 20 else 0.0,
        }
        write_json_atomic(state_path, state)
        with status_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({
                "timestamp": iso_from_ms(tick_ms),
                "phase": state["phase"],
                "desired_capacity": 2,
                "inservice_instances": inservice,
                "healthy_targets": healthy,
                "synthetic": True,
            }, sort_keys=True) + "\n")
        time.sleep(args.tick_seconds)

    availability = summarize_probe_file(
        probe_path, event_ms["failure_injected"], event_ms["recovery_complete"]
    )
    raw = {
        "schema_version": "1.0",
        "synthetic": True,
        "scenario": "synthetic_aws_asg_instance_termination",
        "pre_failure": {"desired_capacity": 2, "inservice_instances": 2, "healthy_targets": 2},
        "post_recovery": {"desired_capacity": 2, "inservice_instances": 2, "healthy_targets": 2},
        "timeline": {
            "failure_injected_at": iso_from_ms(event_ms["failure_injected"]),
            "alb_failure_detected_at": iso_from_ms(event_ms["failure_detected"]),
            "replacement_instance_observed_at": iso_from_ms(event_ms["replacement_started"]),
            "replacement_target_healthy_at": iso_from_ms(event_ms["replacement_healthy"]),
            "final_capacity_convergence_at": iso_from_ms(event_ms["recovery_complete"]),
        },
        "recovery": {"outcome": "success", "total_duration_seconds": 14.0},
        "availability": availability,
        "failure_reason": None,
    }
    write_json_atomic(raw_path, raw)
    print(raw_path)


if __name__ == "__main__":
    main()
