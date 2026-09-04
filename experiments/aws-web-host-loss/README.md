# AWS Web Host Loss experiment

이 디렉터리는 ALB + ASG Terraform을 실제 배포한 뒤에만 사용하는 evidence harness입니다. 현재 단계에서는 실행하지 않았습니다.

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

Runtime JSON/TSV은 `artifacts/`에 저장되고 Git에서 제외됩니다. 공개용 evidence는 secret/account identifiers를 검토·익명화한 뒤 `docs/evidence/`에 별도로 추가합니다.
