# ADR 0001: NAT egress resilience modes

- Status: Accepted for implementation; AWS runtime validation pending
- Date: 2026-09-04

## Context

원본은 AZ1의 단일 NAT instance와 단일 private route table을 두 private subnet이 공유했습니다. NAT host 또는 AZ1이 실패하면 다른 AZ의 egress도 함께 상실합니다. 개선판은 비용을 통제하면서 failure, detection, alternate path, recovery time을 관찰할 수 있어야 합니다.

AWS는 NAT instance보다 NAT Gateway가 높은 가용성과 적은 운영 작업을 제공한다고 안내합니다. Zonal NAT Gateway는 해당 AZ 안에서 중복 구현되지만 여러 AZ가 하나를 공유하면 그 AZ 장애가 다른 AZ의 egress에 영향을 주므로, AWS의 일반적인 resilient reference는 AZ별 NAT Gateway와 AZ-local routing입니다.

References:

- <https://docs.aws.amazon.com/vpc/latest/userguide/VPC_NAT_Instance.html>
- <https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html>
- <https://docs.aws.amazon.com/vpc/latest/userguide/vpc-example-private-subnets-nat.html>
- <https://aws.amazon.com/vpc/pricing/>

## Options

| Criterion | A. AZ별 NAT instance / AZ-local route | B. 장애 시 surviving NAT로 route 변경 | C. ENI 또는 EIP 이동 |
|---|---|---|---|
| Detection | EC2 status check/egress probe | A와 동일, failover trigger 필요 | status check + attachment/association 상태 |
| Failover | 없음. unaffected AZ만 계속 동작 | affected route table의 `0.0.0.0/0` target 교체 | ENI detach/attach 또는 EIP 재연결 후 route/neighbor 상태 확인 |
| Cross-AZ dependency | 정상 경로 없음 | 장애 동안 있음 | 이동 대상/방식에 따라 있으며 AZ 간 ENI 이동은 불가 |
| Route change scope | 없음 | affected app route table 한 개 | route 유지 가능성이 장점이나 attachment sequencing 필요 |
| Recovery time evidence | blast radius만 측정 | alarm → Lambda → route replace → probe 측정 가능 | detach/attach/EIP propagation 단계별 측정 필요 |
| Complexity | 낮음 | 중간 | 높음 |
| AWS cost | NAT용 EC2 2대 + public IPv4 2개 | A와 동일 + 소량의 Lambda/CloudWatch | A와 유사하나 spare/ENI/EIP 구성에 따라 증가 |
| Duplicate/split risk | 자동 action 없음 | duplicate event는 route target 비교로 멱등 처리; alarm race/flapping 위험 | competing attach/association과 partial failure 위험이 큼 |
| Portfolio value | AZ 격리는 선명하지만 affected AZ가 복구되지 않음 | 대체 경로와 recovery duration을 가장 직접적으로 증명 | 네트워크 자원 이동 자체가 목표가 되어 범위를 흐림 |

## Decision

`instance_ha`는 A를 정상 구조로 사용하고 B를 degraded recovery로 결합합니다.

1. 두 NAT instance를 각각 다른 AZ에 둡니다.
2. 각 app subnet은 정상 상태에서 같은 AZ NAT를 사용합니다.
3. 2회 연속 EC2 `StatusCheckFailed`를 CloudWatch alarm으로 감지합니다.
4. EventBridge가 Lambda를 호출합니다.
5. Lambda는 standby instance의 instance/system status가 모두 `ok`인지 확인합니다.
6. affected AZ의 app route만 standby NAT ENI로 교체합니다.
7. duplicate event는 현재 route target을 검사해 no-op으로 처리합니다.

자동 failback은 route oscillation과 정상화 오판을 피하기 위해 이번 범위에 포함하지 않습니다. 원래 AZ로의 복귀는 원인 확인 후 Terraform reconcile/manual runbook 영역입니다. 두 NAT가 동시에 비정상이면 자동 복구하지 않고 `standby_unhealthy` evidence를 남기는 것이 의도한 안전 경계입니다.

## Consequences

- host failure에서는 대체 경로와 시간 측정이 가능합니다.
- failover 동안 cross-AZ 데이터 전송, latency, 비용이 발생할 수 있습니다.
- AZ 전체 장애에서도 surviving AZ가 route API와 Lambda를 처리할 수 있다는 가정은 실제 AWS 실험 전까지 검증되지 않았습니다.
- NAT instance 2대와 public IPv4 2개는 계정의 Free Tier/credit 조건과 별개로 과금 가능성을 사전 확인해야 합니다.
- 이 방식은 저비용 학습 및 장애 실험용이지 production best practice가 아닙니다.
- production reference는 운영 복잡도를 낮추고 AZ 격리를 유지하는 `gateway_per_az`입니다.
