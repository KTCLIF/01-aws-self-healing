# ADR 0004: Local metrics pipeline for AWS experiment visualization

- Status: Accepted
- Date: 2026-09-04

## Decision

Use the existing experiment harness as the timestamp authority. It writes the HTTP probe stream, two-second AWS status samples, and exact lifecycle events to Git-ignored files. A small local exporter converts those files to a fixed Prometheus metric contract; local Prometheus scrapes it once per second and one provisioned Grafana dashboard renders the experiment.

Grafana is limited to the **Resilience Experiment Dashboard**. This decision does not make Grafana or Prometheus the P1 production monitoring control plane and does not extend them to PostgreSQL, NAT, or general application observability.

## Alternatives

| Criterion | Grafana CloudWatch datasource | Harness → local exporter → Prometheus |
|---|---|---|
| Additional AWS cost | CloudWatch API use may be billable | None |
| AWS resources | No server, but AWS datasource credentials are required | None |
| Timestamp alignment | CloudWatch aggregation/delay differs from the 250ms probe and 2s poll | Harness timestamps remain authoritative |
| Screenshot | Native AWS metrics, but the request and lifecycle axes can lag | HTTP, capacity, and events share one local time axis |
| Local reproducibility | Requires a live account and credentials | Full synthetic dry run works offline after images are present |
| Public safety | Grafana must receive AWS credentials | No AWS credentials enter the dashboard stack |
| Complexity | Fewer local components, more credential and query handling | Three narrow local containers and no plugin |

CloudWatch remains useful as supporting AWS Console evidence, but is not the Grafana datasource for this experiment.

## Consequences

- No Terraform monitoring resources are added.
- Raw files can include AWS identifiers and remain ignored.
- Curated JSON and Markdown remove account IDs, instance IDs, IP addresses, DNS names, and ARNs.
- The dashboard is reproducible from tracked Compose, Prometheus, provisioning, and dashboard JSON files.
- Prometheus samples are visualization evidence; raw harness timestamps remain the source for recovery-duration calculations.

## References

- <https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/>
- <https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/aws-authentication/>
- <https://aws.amazon.com/cloudwatch/pricing/>
