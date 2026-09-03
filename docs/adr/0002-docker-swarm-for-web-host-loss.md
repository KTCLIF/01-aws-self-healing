# ADR 0002: Docker Swarm for the Web Host Loss experiment

- Status: Accepted for the bounded web workload experiment
- Date: 2026-09-04

## Decision

Docker Swarm을 Web Host Loss scenario의 workload desired-state/rescheduling mechanism으로 제한적으로 채택합니다.

채택 범위는 “worker host를 잃었을 때 surviving worker에 단일 stateless web task를 다시 만들고 recovery time을 측정한다”입니다. PostgreSQL, monitoring/recovery control plane, 전체 production platform으로 확장하지 않습니다.

## Evidence

격리된 1 manager + 2 worker Docker-in-Docker Swarm에서 같은 service를 대상으로 두 실험을 실행했습니다.

| Scenario | Injection | Detection | Ready | HTTP recovered | Total | Result |
|---|---|---:|---:|---:|---:|---|
| Process Failure | workload container kill | 0.378s | 7.762s | 7.813s | 7.813s | success |
| Host Failure | workload가 있던 worker daemon stop | 13.563s | 21.914s | 21.961s | 21.961s | success |

두 실험 모두 single replica이므로 실제 service interruption을 관찰했습니다. Host Failure에서는 task가 worker A에서 worker B로 이동했습니다. Curated raw timestamps는 `docs/evidence/web-host-loss-local-20260904.json`에 있습니다.

## Why this is meaningful

- Process Failure는 host가 살아 있어 기존 Recovery Controller → Ansible/service restart로도 처리할 수 있습니다.
- Host Failure는 action을 실행할 target host가 사라졌으므로 service restart로 복구할 수 없습니다.
- Swarm은 별도의 alert webhook action 없이 desired replica를 surviving node에 생성했습니다.
- detection, rescheduling, Ready, HTTP recovery를 분리해 측정할 수 있었습니다.

## Costs and limitations

- scheduler, overlay/routing mesh, node lifecycle이라는 추가 운영 복잡도가 생깁니다.
- local PoC manager는 한 대이므로 manager HA를 증명하지 않습니다.
- single replica가 복구되는지를 측정했으며 무중단 HA를 증명하지 않습니다.
- Docker-in-Docker worker stop은 EC2 termination, AZ loss, 실제 network partition과 동일하지 않습니다.
- 외부 ALB 관점의 health check와 traffic success rate는 아직 포함하지 않았습니다.

이 한계를 감안해도 기존 process restart와 host rescheduling의 경계를 실행 결과로 보여주므로 포트폴리오 가치가 추가 복잡도보다 큽니다. AWS 단계에서는 EC2 Auto Scaling/ECS와의 대안 비교 없이 Swarm을 production 정답으로 주장하지 않습니다.
