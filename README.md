# 01-aws-self-healing

AWS 장애 탐지와 자동 복구를 서비스 프로세스 수준에서 **Resilience / HA / DR** 검증으로 확장하는 개인 포트폴리오 프로젝트입니다.

> 이 저장소는 2026년 4~5월 팀 프로젝트 `/home/user1/project1-aws`의 후속 개인 개선판입니다. 원본의 아이디어와 일부 구현을 선별해 계승하지만, 원본 저장소의 복제본이나 팀 결과물의 수정본이 아닙니다. 원본은 읽기 전용 기준 자료로 보존하며 이 저장소는 별도의 Git 이력과 책임 범위를 갖습니다.

## 목표 흐름

```text
failure injection
  -> Prometheus detection
  -> Alertmanager routing
  -> Recovery Controller policy
  -> Ansible recovery
  -> post-recovery validation
  -> machine-readable evidence (detection/recovery time, outcome)
```

핵심 질문은 “프로세스를 다시 시작했는가?”가 아니라 다음과 같습니다.

- 한 AZ 또는 host가 사라져도 서비스의 desired state가 유지되는가?
- data plane과 recovery/monitoring control plane에 단일 장애 지점이 남아 있는가?
- PostgreSQL의 failover와 복구가 명시한 RPO/RTO 안에서 완료되는가?
- 복구 성공 여부와 시간을 반복 가능한 테스트 결과로 증명할 수 있는가?

Docker Swarm은 목표가 아니라 host 장애 시 workload rescheduling을 검증할 때만 선택할 수 있는 수단입니다.

## 현재 구현 범위

- 독립 Git 저장소와 비밀정보/state/key 차단 규칙
- 2-AZ VPC와 AZ별 private route table
- `none`(기본), 학습용 `instance_ha`, production reference인 `gateway_per_az` NAT mode
- `instance_ha`의 AZ-local 정상 경로와 장애 시 surviving NAT로의 event-driven degraded route failover
- 원본의 Prometheus alert rule을 선별해 보존한 초기 rule set
- 원본 Recovery Controller 흐름을 재구성한 webhook controller
  - firing alert만 실행
  - policy allowlist 기반 script 실행
  - retry/cooldown/timeout
  - 후속 검증
  - alert별 JSON 응답과 JSONL runtime evidence
- AWS 없이 실행하는 controller 자동 테스트와 정적 검증 명령
- 격리된 Docker-in-Docker Swarm Web Host Loss 실험
  - process failure와 host failure를 같은 evidence contract로 비교
  - surviving worker rescheduling과 HTTP recovery 시간 측정
- 기본 비활성화된 AWS Web Host Loss 정적 구성
  - 2-AZ ALB + desired capacity 2 ASG
  - ELB health 기반 instance replacement
  - continuous HTTP/target health/capacity evidence harness

아직 AWS 리소스를 생성하거나 실제 HA failover를 수행하지 않았습니다. `terraform apply`는 자동화 검증 명령에 포함되지 않습니다.

## 빠른 검증

```bash
make check
```

개별 명령은 다음과 같습니다.

```bash
make test          # Recovery Controller unit/integration-style tests
make terraform-fmt # Terraform formatting check
make terraform-validate
make secret-scan   # tracked candidate 파일의 대표적인 secret/state 패턴 검사
```

Terraform provider 초기화는 다운로드만 수행하며 AWS 리소스를 만들지 않습니다.

```bash
make terraform-init
```

## 구조

```text
.
├── docs/
│   ├── architecture.md       # 목표 구조, failure domains, 현재 경계
│   ├── provenance.md         # 원본에서 계승/제외한 항목
│   └── validation.md         # evidence와 검증 단계
├── infra/terraform/          # 비용 발생 없는 상태로 시작하는 2-AZ network baseline
├── experiments/web-host-loss/# process/host failure local PoC
├── observability/prometheus/ # 선별 계승한 alert rules
├── recovery/controller/      # policy-driven webhook controller와 tests
├── tests/evidence/           # evidence schema/fixture용 추적 디렉터리
└── Makefile
```

## 안전 및 비용 경계

- 기본 `nat_mode = "none"`이므로 private subnet에 인터넷 기본 경로를 만들지 않습니다.
- `instance_ha`는 저비용 학습/장애 검증용이며 production best practice로 제시하지 않습니다.
- `gateway_per_az`는 AZ 격리와 운영 단순성을 우선하는 production reference입니다. NAT Gateway는 시간당/처리량 비용이 발생합니다.
- Terraform state, tfvars, private key, inventory, credential, runtime evidence는 Git에서 제외합니다.
- 이 단계에서는 `plan/apply/destroy`, GitHub Actions, 외부 webhook 호출을 수행하지 않습니다.

## 다음 우선순위

1. Web Host Loss evidence를 AWS host termination scenario와 연결
2. NAT `instance_ha`의 CloudWatch 감지/route failover를 최소 AWS 환경에서 측정
3. monitoring/recovery control plane 이중화 모델과 중복 실행 방지 설계
4. PostgreSQL 후보 비교 후 RPO/RTO가 있는 failover test 구현

상세한 현재/목표 구조는 [docs/architecture.md](docs/architecture.md), 계승 근거는 [docs/provenance.md](docs/provenance.md)를 참고합니다.

Web Host Loss 판정은 [ADR 0002](docs/adr/0002-docker-swarm-for-web-host-loss.md), 실제 local 결과는 [curated evidence](docs/evidence/web-host-loss-local-20260904.json)에 기록했습니다.

Multi-replica availability 실험은 최종 convergence에 성공했지만 간헐적 오류가 있어 무중단으로 판정하지 않았습니다. 결과는 [availability 비교](docs/web-availability-results.md)와 [multi-replica evidence](docs/evidence/web-multi-replica-host-loss-local-20260904.json)에 있습니다.

AWS Web Host Loss는 [ADR 0003](docs/adr/0003-aws-web-host-recovery.md)에 따라 ALB+ASG로 검증하며, 실제 실행 전까지 `enable_web_asg=false`를 유지합니다.
