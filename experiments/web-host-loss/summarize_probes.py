#!/usr/bin/env python3
"""Summarize continuous HTTP probe TSV without external dependencies."""

import argparse
import json
import statistics


def parse_lines(lines):
    samples = []
    for line in lines:
        parts = line.rstrip("\n").split("\t", 3)
        if len(parts) != 4:
            continue
        epoch_ms, timestamp, success, serving_node = parts
        samples.append({
            "epoch_ms": int(epoch_ms),
            "timestamp": timestamp,
            "success": success == "1",
            "serving_node": serving_node or None,
        })
    return samples


def _max_failure_run(samples, interval_ms):
    maximum_count = 0
    maximum_duration_ms = 0
    run_count = 0
    run_start = None
    previous_ms = None

    for sample in samples:
        if not sample["success"]:
            if run_count == 0:
                run_start = sample["epoch_ms"]
            run_count += 1
            previous_ms = sample["epoch_ms"]
            maximum_count = max(maximum_count, run_count)
        elif run_count:
            maximum_duration_ms = max(maximum_duration_ms, sample["epoch_ms"] - run_start)
            run_count = 0
            run_start = None

    if run_count:
        maximum_duration_ms = max(maximum_duration_ms, previous_ms - run_start + interval_ms)
    return maximum_count, maximum_duration_ms / 1000.0


def summarize(samples, failure_ms, convergence_ms, interval_ms):
    window = [sample for sample in samples if failure_ms <= sample["epoch_ms"] <= convergence_ms]
    successes = sum(1 for sample in samples if sample["success"])
    failures = len(samples) - successes
    window_failures = sum(1 for sample in window if not sample["success"])
    max_failures, max_unavailable = _max_failure_run(window, interval_ms)

    before_nodes = sorted({
        sample["serving_node"] for sample in samples
        if sample["success"] and sample["epoch_ms"] < failure_ms and sample["serving_node"]
    })
    after_nodes = sorted({
        sample["serving_node"] for sample in samples
        if sample["success"] and sample["epoch_ms"] > convergence_ms and sample["serving_node"]
    })
    error_rate = (window_failures / len(window) * 100.0) if window else 0.0
    observed_intervals = [
        right["epoch_ms"] - left["epoch_ms"]
        for left, right in zip(samples, samples[1:])
    ]

    return {
        "probe_interval_ms": interval_ms,
        "observed_average_start_interval_ms": round(
            sum(observed_intervals) / len(observed_intervals), 3
        ) if observed_intervals else None,
        "observed_median_start_interval_ms": statistics.median(
            observed_intervals
        ) if observed_intervals else None,
        "observed_max_start_interval_ms": max(observed_intervals) if observed_intervals else None,
        "total_requests": len(samples),
        "successful_requests": successes,
        "failed_requests": failures,
        "failure_window_requests": len(window),
        "failure_window_failed_requests": window_failures,
        "failure_window_error_rate_percent": round(error_rate, 3),
        "max_consecutive_failures": max_failures,
        "max_unavailable_duration_seconds": round(max_unavailable, 3),
        "serving_nodes_before_failure": before_nodes,
        "serving_nodes_after_convergence": after_nodes,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("probe_log")
    parser.add_argument("--failure-ms", type=int, required=True)
    parser.add_argument("--convergence-ms", type=int, required=True)
    parser.add_argument("--interval-ms", type=int, required=True)
    args = parser.parse_args()
    with open(args.probe_log, encoding="utf-8") as stream:
        samples = parse_lines(stream)
    print(json.dumps(summarize(
        samples, args.failure_ms, args.convergence_ms, args.interval_ms
    ), sort_keys=True))


if __name__ == "__main__":
    main()
