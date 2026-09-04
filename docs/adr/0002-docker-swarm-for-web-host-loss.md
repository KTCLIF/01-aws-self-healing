# ADR 0002: Docker Swarm for the Web Host Loss experiment

- Status: Accepted only for local stateless web resilience experiments
- Date: 2026-09-04

## Decision

Docker Swarm을 local Web Host Loss scenario의 workload desired-state/rescheduling mechanism으로 제한적으로 채택합니다.

채택 범위는 process/worker host failure에서 stateless web task의 desired state, rescheduling, service availability를 비교하는 local 실험입니다. PostgreSQL, monitoring/recovery control plane, AWS production architecture, 모든 workload의 공통 orchestrator로 확장하지 않습니다.

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

## Multi-replica availability follow-up

2 replicas를 서로 다른 worker에 배치하고 active worker 하나를 상실시킨 결과, 최종 desired state는 20.417초에 복구됐지만 continuous probe 137건 중 6건이 실패했습니다. 장애~수렴 구간 error rate는 6.061%, 최대 연속 실패는 1건, 최대 unavailable 관찰치는 1.169초였습니다.

따라서 Swarm은 host loss를 복구했지만 이 구성에서 무중단을 보장하지 않았습니다. 이 결과로 역할 경계를 local resilience mechanism으로 고정하며 AWS web recovery 선택 근거로 자동 승격하지 않습니다.
