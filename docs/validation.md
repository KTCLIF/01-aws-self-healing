# Validation and runtime evidence

## Evidence contract

Controller는 각 alert 처리 결과를 한 줄 JSON(JSONL)으로 기록합니다. 필수 필드는 다음과 같습니다.

- `event_id`: 요청별 correlation id
- `alertname`, `instance`, `status`
- `outcome`: `success`, `failed`, `skipped`, `unmapped`
- `attempts`
- `started_at`, `finished_at`, `duration_seconds`
- `reason`

로그 위치는 `RECOVERY_EVIDENCE_FILE`로 지정하며 기본값은 `artifacts/recovery-events.jsonl`입니다. 이 경로는 Git 추적에서 제외됩니다.

## Local validation

`make check`는 다음을 실행합니다.

1. Python compile 및 controller tests
2. Terraform format/validate
3. YAML/JSON parse
4. shell syntax
5. tracked candidate secret/state pattern scan

Controller tests는 성공, cooldown, unknown alert, resolved alert skip, retry failure, invalid JSON을 검증합니다. AWS나 실제 Ansible inventory는 사용하지 않습니다.

## Cloud validation (not run yet)

후속 E2E scenario마다 최소한 다음 시각을 수집합니다.

```text
t0 failure injected
t1 Prometheus condition observed
t2 alert firing / webhook received
t3 recovery action started
t4 service SLI healthy
t5 alert resolved
```

- MTTD = `t2 - t0`
- action time = `t4 - t3`
- observed recovery time = `t4 - t0`

성공 판정은 process 상태뿐 아니라 외부 SLI와 desired capacity를 함께 검사해야 합니다.
