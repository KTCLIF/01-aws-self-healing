# Resilience Experiment Dashboard

This is a single-purpose local visualization stack for the AWS Web Host Loss experiment. It is not an AWS monitoring tier and is not the P1 production observability control plane.

## Pipeline

```text
continuous HTTP probe ─┐
                      ├─ Git-ignored harness files → local exporter → Prometheus → Grafana
AWS API polling ───────┘
```

- Probe interval: 250ms by default.
- AWS status poll: 2s.
- Prometheus scrape: 1s.
- Grafana refresh: 1s; default view: last 15 minutes in UTC.
- AWS credentials: never mounted or passed to this stack.
- Persistent storage: none; Prometheus and Grafana data are ephemeral.

The raw harness timestamps, rather than Prometheus scrape timestamps, are authoritative for duration calculations.

## Metric contract

| Metric | Meaning |
|---|---|
| `p1_http_probe_success` | Latest probe outcome, 1 or 0 |
| `p1_http_availability_percent` | Cumulative request availability |
| `p1_http_error_rate_percent` | Cumulative request error rate |
| `p1_http_requests_*` | Exact cumulative probe counts |
| `p1_alb_healthy_targets` | Healthy targets from ELBv2 API polling |
| `p1_asg_inservice_instances` | Healthy InService instances from ASG polling |
| `p1_asg_desired_capacity` | ASG desired capacity |
| `p1_experiment_phase` | Ordered baseline/failure/replacement/recovery phase |
| `p1_event_reached` | Event state used by the event timeline and annotations |
| `p1_event_timestamp_seconds` | Exact harness event time |
| `p1_recovery_duration_seconds` | Injection-to-convergence duration |
| `p1_synthetic_evidence` | 1 for mock feed, 0 for AWS harness feed |

## Commands

```bash
make resilience-dashboard-dry-run  # synthetic E2E validation, then stop
make resilience-dashboard-up       # fresh empty stack for the AWS experiment
make resilience-dashboard-down     # stop and remove only this local stack
```

Dashboard URL: `http://127.0.0.1:33000/d/p01-resilience`

The dashboard, datasource, and panels are provisioned from tracked files. Generated mock and runtime evidence stays under the ignored AWS experiment `artifacts/` directory.
