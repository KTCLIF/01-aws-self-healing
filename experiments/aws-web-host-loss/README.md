# AWS Web Host Loss experiment

이 디렉터리는 ALB + ASG Terraform을 실제 배포한 뒤에만 사용하는 evidence harness입니다. 현재 단계에서는 실행하지 않았습니다.

Account/state isolation과 apply/destroy 순서는 `docs/aws-web-host-loss-runbook.md`를 먼저 따릅니다.

## Local visualization

Grafana는 AWS CloudWatch에 직접 접속하지 않습니다. 이 harness가 쓰는 Git-ignored probe/state 파일을 local exporter와 Prometheus가 읽습니다.

```bash
make resilience-dashboard-dry-run
```

실제 실험 직전에는 `make resilience-dashboard-up`으로 mock history가 없는 새 stack을 시작합니다. 기본 URL은 `http://127.0.0.1:33000/d/p01-resilience`입니다. Mock feed는 언제나 `synthetic=true`이며 실제 AWS runtime evidence가 아닙니다.

## Safety gate

`run-experiment.sh`는 `EXECUTE_AWS_HOST_LOSS=yes`가 없으면 종료합니다. 실행하면 ASG의 healthy instance 한 대를 실제 terminate합니다.

필수 입력은 Terraform output에서 얻습니다.

```bash
export WEB_ASG_NAME="$(terraform -chdir=infra/terraform output -raw web_asg_name)"
export WEB_TARGET_GROUP_ARN="$(terraform -chdir=infra/terraform output -raw web_target_group_arn)"
export WEB_ALB_URL="$(terraform -chdir=infra/terraform output -raw web_alb_url)"
export AWS_REGION=ap-northeast-2

EXECUTE_AWS_HOST_LOSS=yes ./experiments/aws-web-host-loss/run-experiment.sh
```

## Collected evidence

- selected instance termination and timestamp
- ALB target state transition
- ASG desired/current healthy capacity
- replacement instance first observation
- replacement target health pass
- final capacity/healthy-target convergence
- continuous ALB HTTP probe counts, error rate, consecutive failures, unavailable duration
- pre/post serving instance IDs returned by the stateless test app
- raw two-second AWS capacity/target state transitions
- local dashboard metric state and exact lifecycle event timestamps
- identifier-free curated JSON and Markdown summary candidates

Runtime JSON/TSV은 `artifacts/`에 저장되고 Git에서 제외됩니다. 공개용 evidence는 secret/account identifiers를 검토·익명화한 뒤 `docs/evidence/`에 별도로 추가합니다.
