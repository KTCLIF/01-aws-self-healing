# 원본과 개인 개선판의 경계

## 기준 자료

- 원본: `/home/user1/project1-aws`
- 원본 기준 branch/commit: `dev` / `e1a1df4`
- 확인일: 2026-09-04
- 원본은 이 작업에서 수정하지 않았습니다.

## 선별 계승

| 원본 자산 | 개선판 위치 | 계승 이유 | 변경 방향 |
|---|---|---|---|
| `recovery/controller/app.py` | `recovery/controller/app.py` | Alertmanager webhook → policy → script → verify 흐름 | 실행 정책 검증, 구조화 evidence, 테스트 가능성 추가 |
| `recovery/controller/config/recovery_map.yml` | 같은 상대 위치 | alertname 기반 복구 매핑 | shell 문자열 검증을 제거하고 argv 기반 verify로 제한 |
| controller test payloads | `recovery/controller/tests/fixtures/` | 대표 alert 계약 | host/IP 중립 fixture로 변경 |
| recovery scripts | `recovery/controller/scripts/` | mock/Ansible 실행 모드 | 원본 절대 경로 제거, 명시적 inventory 요구 |
| `alert.rules.yml` | `observability/prometheus/alert.rules.yml` | 탐지 단계의 초기 기준 | 문구/지속시간 불일치 수정, 향후 host/control-plane rule 확장 |
| 2-AZ subnet 아이디어 | `infra/terraform/` | multi-AZ failure domain의 출발점 | 단일 NAT instance와 key 생성 제거, AZ별 routing 구성 |

## 제외

- Terraform state/backup, `.terraform/`, tfvars, 생성된 PEM/public key, inventory, apply log
- 단일 NAT EC2와 단일 private route table
- Terraform이 private key를 생성해 로컬에 쓰는 구성
- Terraform `local-exec`로 Ansible을 자동 실행하는 결합
- 단일 mgmt host에 Prometheus/Grafana/Alertmanager/Recovery Controller를 모두 설치하는 role
- 단일 EC2 PostgreSQL role과 고정 DB endpoint 가정
- Tailscale credential/provider 및 온프레미스 경로: 이번 HA/DR 검증 목표에 필수라는 근거가 아직 없음
- 기존 setup/demo/team workflow 문서 및 Grafana dashboard: 새 검증 계약이 정해진 뒤 필요한 부분만 재작성
- reference/legacy 구현과 실행 로그

## 실제 코드와 기존 설명의 차이

원본 README의 일부 도식과 주석은 `NAT Gateway`를 언급하지만 실제 `terraform/main.tf`는 AZ1의 단일 `aws_instance.nat_ec2`를 두 private subnet이 공유합니다. 이 개선판은 실제 코드를 기준으로 이를 NAT instance SPOF로 판정했습니다.

원본 alert `NginxDown`은 `for: 5s`인데 description은 10초 이상이라고 설명합니다. 개선판은 10초로 일치시켰습니다.

원본 controller는 recovery script 성공 후 verify command를 `shell=True`로 실행하며, mock recovery에서도 실제 host 검증 명령이 필요했습니다. 개선판은 정책에 argv list만 허용하고 fixture별 mock verify script로 local test가 가능하도록 재구성했습니다.
