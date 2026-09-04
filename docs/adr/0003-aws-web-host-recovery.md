# ADR 0003: ALB + Auto Scaling Group for AWS Web Host Recovery

- Status: Accepted for static implementation; AWS validation pending
- Date: 2026-09-04

## Context

Local Swarm PoC는 stateless workload의 host-loss rescheduling을 보여줬습니다. AWS 단계에서는 같은 기능을 반복하는 것보다 사용자 관점의 HTTP availability, target health 변화, desired capacity restoration을 AWS failure domain에서 측정할 mechanism이 필요합니다.

References:

- <https://docs.aws.amazon.com/autoscaling/ec2/userguide/health-checks-overview.html>
- <https://docs.aws.amazon.com/autoscaling/ec2/userguide/attach-load-balancer-asg.html>
- <https://docs.aws.amazon.com/autoscaling/ec2/userguide/disaster-recovery-resiliency.html>
- <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html>
- <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html>
- <https://aws.amazon.com/elasticloadbalancing/pricing/>

## Comparison

| Criterion | Docker Swarm on EC2 | ALB + Auto Scaling Group |
|---|---|---|
| Host termination | manager가 node loss 후 task reschedule | ASG가 non-running/unhealthy instance를 교체 |
| Desired capacity | Swarm service replicas | ASG min/max/desired capacity |
| Health check | container task/Swarm state, 별도 external check 필요 | ALB HTTP target health + EC2 health를 ASG에 연결 |
| Traffic draining | Swarm routing mesh/task lifecycle에 의존 | target deregistration delay; abrupt host loss에는 기존 connection 보호 불가 |
| Replacement provisioning | surviving worker에 container pull/start | launch template으로 새 EC2 boot/user-data/target registration |
| Failure detection | manager heartbeat/node state | EC2 state/status + ALB health threshold |
| Recovery measurement | manager/task state와 external probe 조합 | target health, ASG activity/capacity, ALB continuous probe |
| Multi-AZ | overlay network와 node placement를 직접 운영 | ASG subnet/AZ balancing + multi-AZ ALB |
| Operations | manager quorum, join token, overlay, upgrade 필요 | managed ALB/ASG; instance image/bootstrap은 관리 필요 |
| Cost | EC2 manager/worker 수와 traffic 비용 | EC2 2대 + ALB hourly/LCU + traffic 비용 |
| Free Tier/minimum lab | 1 manager+2 workers는 instance 수가 증가; single manager는 SPOF | desired=2가 필요하며 ALB는 계정별 credit/free offer 확인 필요 |
| Portfolio value | local PoC와 의미가 중복되고 Swarm 운영이 주제가 됨 | AWS-native host replacement와 user-facing availability를 직접 증명 |

## Decision

AWS Web Host Loss 검증은 **ALB + Auto Scaling Group**으로 수행합니다.

- public ALB는 두 public subnet에 배치합니다.
- stateless web ASG는 두 private app subnet을 사용하고 desired capacity 2를 유지합니다.
- ALB만 instance port 8080에 접근할 수 있습니다.
- ALB `/health` 결과를 ASG health에 포함합니다.
- host termination 후 surviving healthy target이 traffic을 처리하는 동안 ASG가 launch template으로 replacement를 생성합니다.
- 성공은 replacement 자체가 아니라 continuous HTTP error rate와 healthy target/capacity convergence로 판단합니다.

## Boundaries

- 이 선택은 AWS web tier에 한정합니다. Swarm의 local 실험 역할을 폐기하거나 AWS production orchestrator로 확장하지 않습니다.
- ALB health check 5초 × unhealthy threshold 2는 빠른 실험 설정이며 production SLO에 맞춘 값이라는 주장은 하지 않습니다.
- graceful scale-in에는 15초 deregistration delay가 적용되지만 abrupt termination의 in-flight request는 보호하지 못합니다.
- `enable_web_asg=false`가 기본이며 실제 비용 승인 전에는 생성하지 않습니다.
- ALB는 실행 시간과 LCU에 따라 과금됩니다. EC2와 public IPv4/traffic 및 계정의 credit 적용 여부를 실제 실행 전에 확인해야 합니다.
