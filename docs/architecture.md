# Architecture baseline

## Failure domains

```text
Region
├── AZ A: public subnet -> optional NAT A; private app/data subnets
└── AZ B: public subnet -> optional NAT B; private app/data subnets
```

각 private subnet은 정상 상태에서 같은 AZ의 egress에만 연결합니다. `instance_ha`는 NAT instance host 장애를 감지하면 affected route만 surviving NAT instance로 바꾸는 degraded cross-AZ 경로를 사용합니다. `gateway_per_az`에서는 한 NAT/AZ 장애가 다른 AZ의 egress까지 끊지 않도록 route table을 분리합니다. 기본값 `none`은 비용과 의도치 않은 외부 통신을 막기 위한 local-validation 설정입니다.

## Target resilience model

| Layer | Original behavior | Target behavior | Current state |
|---|---|---|---|
| Egress | AZ1 단일 NAT instance | 학습용 route failover 또는 AZ별 managed NAT | Terraform/handler 구현, cloud 미검증 |
| Web workload | 2 EC2의 service restart | local Swarm availability 비교; AWS ALB+ASG capacity/traffic recovery | Terraform 구현, AWS 미검증 |
| PostgreSQL | 단일 EC2 PostgreSQL restart | replica/failover/backup restore + RPO/RTO evidence | 미구현 |
| Monitoring | 단일 mgmt host | 감시 자체 장애를 탐지하고 지속 가능한 control plane | 미구현 |
| Recovery | 단일 in-memory cooldown | 중복 실행 방지, idempotency, controller failover | local controller/evidence만 구현 |
| Validation | 수동 payload/chaos demo | 자동 scenario contract + machine-readable results | controller tests 구현, E2E 미구현 |

## Guardrails

- 자동 복구 action은 policy 파일에 등록한 executable만 실행합니다.
- webhook label을 shell command로 결합하지 않습니다.
- recovery script는 기본 mock mode이고, Ansible mode에는 명시적 inventory가 필요합니다.
- infrastructure provisioning과 configuration/recovery를 분리합니다.
- runtime evidence는 저장소 밖의 `artifacts/`에 생성합니다.

## Decision gates before adding technology

- Docker Swarm은 local stateless web resilience 실험에만 사용합니다. AWS web 검증은 ADR 0003에 따라 ALB+ASG를 사용합니다.
- PostgreSQL은 RPO/RTO, 비용 한도, 자동 failover 범위를 먼저 정한 뒤 RDS Multi-AZ, self-managed replication 등을 비교합니다.
- control plane은 active/active 여부보다 alert deduplication과 recovery action idempotency를 먼저 설계합니다.
