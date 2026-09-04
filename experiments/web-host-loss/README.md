# Web Host Loss local experiment

## Question

Web workload process만 죽은 경우와 workload가 있던 host 자체가 사라진 경우에 복구 주체와 결과가 어떻게 다른가?

## Isolated topology

```text
outer Docker daemon
└── dedicated bridge network
    ├── Docker-in-Docker manager
    ├── Docker-in-Docker worker A
    └── Docker-in-Docker worker B
```

실험은 기존 Docker container나 host Swarm state를 변경하지 않습니다. run별 고유 이름을 가진 privileged Docker-in-Docker container와 network만 만들고 종료 시 제거합니다. runtime JSON은 `artifacts/`에 생성되며 Git에서 제외됩니다.

## Scenarios

```bash
make web-host-loss-process
make web-host-loss-host
make web-host-loss-multi
```

`process`는 workload container만 kill합니다. host는 살아 있으므로 기존 Ansible/service restart와 같은 process-level 복구 영역이며 Swarm도 task를 다시 만듭니다.

`host`는 workload가 실행 중인 worker Docker daemon container를 중지합니다. 사라진 host에는 Ansible/service restart를 실행할 수 없습니다. manager가 node loss를 감지하고 surviving worker에 desired task를 reschedule해야 성공입니다.

두 scenario 모두 단일 replica를 사용해 failure window를 의도적으로 노출합니다. 고가용 서비스 구성이라면 replica를 failure domain에 분산하고 외부 load balancer 관점의 연속 성공률도 별도로 측정해야 합니다.

`multi`는 worker 3대에 replica 2개를 node당 최대 하나로 분산합니다. workload가 있는 worker 하나를 중지하고 100ms configured interval의 continuous HTTP probe를 유지하면서 surviving replica의 가용성과 spare worker로의 최종 replica convergence를 함께 측정합니다.

## Evidence

`evidence.schema.json`은 다음 시각을 필수 계약으로 정의합니다.

- failure injection
- failure detection
- recovery/rescheduling start
- new workload Ready
- service response recovered
- total/detection/rescheduling duration
- failure reason

이 local PoC의 detection은 Swarm control plane이 기존 task를 대체 task로 변경한 관찰 시점입니다. Prometheus/Alertmanager 감지 시간은 향후 E2E 계층에서 별도로 추가합니다.

## Observed multi-replica result

2026-09-04 실행에서는 2 replicas가 worker-a/worker-b에 분산됐고 worker-b stop 후 worker-c로 수렴했습니다. 20.417초에 desired replicas가 복구됐지만 continuous probe에서 6건의 간헐적 failure가 관찰되어 무중단으로 판정하지 않았습니다.

상세 비교와 probe sampling 제약은 `docs/web-availability-results.md`, 공개 가능한 curated evidence는 `docs/evidence/web-multi-replica-host-loss-local-20260904.json`에 있습니다.
