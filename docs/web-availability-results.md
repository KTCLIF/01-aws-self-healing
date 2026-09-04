# Local Web Availability result

## Result

Multi-replica Host Loss는 복구와 최종 수렴에는 성공했지만 무중단은 아니었습니다.

| Metric | Single replica host loss | Multi-replica host loss |
|---|---:|---:|
| Desired replicas | 1 | 2, 서로 다른 worker |
| Spare worker | 1 | 1 |
| Host-loss detection | 13.563s | 14.920s |
| Final Ready/convergence | 21.961s | 20.417s |
| HTTP probe | recovery 확인용 polling | continuous, configured 100ms |
| Requests | 해당 없음 | 137 total / 131 success / 6 failure |
| Failure-window error rate | availability 표본 없음 | 6.061% (6/99) |
| Max consecutive failures | 해당 없음 | 1 |
| Max observed unavailable duration | 복구까지 unavailable | 1.169s |
| Serving nodes | worker-a → worker-b | worker-a+worker-b → worker-a+worker-c |

100ms는 probe 사이의 configured sleep입니다. Docker CLI/exec와 request 시간이 더해져 실제 probe 시작 간격은 평균 193.441ms, 중앙값 156.5ms였고 timeout이 발생한 최대 간격은 1169ms였습니다.

## Interpretation

- Recovery Time은 desired replica 수가 원래 값으로 돌아오는 시간입니다. Multi-replica도 약 20초가 필요했습니다.
- Service Availability는 그 수렴을 기다리는 동안 요청이 처리됐는지입니다. Surviving replica가 대부분의 요청을 처리했지만 routing mesh가 failed task를 제거하기 전 간헐적 timeout이 발생했습니다.
- 따라서 이 결과는 `zero-downtime`이 아니라 `degraded_with_intermittent_errors`로 판정합니다.
- 단일 replica 결과만으로는 recovery 가능성만 설명할 수 있고, continuous probe가 있어야 사용자 관점의 가용성을 설명할 수 있습니다.

이 local 결과를 AWS ALB의 동작으로 일반화하지 않습니다. AWS 검증에서는 ALB DNS를 직접 probe하고 target health와 ASG activity를 별도 timestamp로 수집해야 합니다.
