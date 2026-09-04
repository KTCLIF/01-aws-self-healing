# AWS Web Host Loss experiment runbook

## Hard isolation gates

1. Use a dedicated CLI profile for the personal P1 account; do not rely on whichever `default` credential is active.
2. Set the expected personal account ID only in the shell environment or ignored tfvars.
3. Run the account guard and stop on any mismatch.
4. Use region `ap-northeast-2` unless a new estimate/plan explicitly approves another region.
5. Confirm the P1 state path is `infra/terraform/state/p01-self-healing.tfstate` and the integration project state is elsewhere.
6. Confirm plan actions contain create only and no existing ID is imported or referenced.
7. Confirm all taggable resources inherit `Project=01-aws-self-healing`, `Owner=KTCLIF`, `Purpose=portfolio-resilience-test` and names use `p01-self-healing`.

```bash
export AWS_PROFILE=p1-personal
export P1_EXPECTED_ACCOUNT_ID='<personal account ID>'
export P1_EXPECTED_REGION=ap-northeast-2
./scripts/aws-account-guard.sh

export TF_VAR_aws_profile="$AWS_PROFILE"
export TF_VAR_expected_account_id="$P1_EXPECTED_ACCOUNT_ID"
```

Do not paste the account ID into tracked files or command examples.

## Approved experiment variables

Create an ignored `infra/terraform/terraform.tfvars` with:

```hcl
resource_prefix  = "p01-self-healing"
region           = "ap-northeast-2"
nat_mode         = "none"
enable_web_asg   = true
web_instance_type = "t3.micro"
web_ingress_cidrs = ["<operator-public-ip>/32"]
```

`aws_profile` and `expected_account_id` remain environment variables where practical.

## Execution

1. Run `terraform init -reconfigure`, `terraform plan`, review create-only actions, then explicitly approve `terraform apply`.
2. Wait for ASG `2/2 InService` and ALB target group `2/2 healthy`.
3. Export `WEB_ASG_NAME`, `WEB_TARGET_GROUP_ARN`, and `WEB_ALB_URL` from Terraform outputs.
4. Start the continuous HTTP probe through `run-experiment.sh`; it records a 10-second baseline before failure.
5. The harness selects one current `InService` instance explicitly and records its ID only in ignored runtime evidence.
6. Set `EXECUTE_AWS_HOST_LOSS=yes` only after verifying the selected account/profile/region and target.
7. The harness re-runs the account guard with the explicit profile, then terminates that instance.
8. Record victim ALB target transition away from `healthy`.
9. Record the first replacement instance observed in the ASG.
10. Wait for the replacement target to become `healthy`.
11. Require ASG `2/2 InService` and ALB `2/2 healthy`, then collect a 10-second post-recovery probe window.
12. Stop the probe and generate ignored JSON/TSV evidence.
13. Run `terraform destroy` with the same guarded profile, account, region, variables, and P1 state.
14. Verify P1-tagged EC2, EBS, ALB, target group, ASG, launch template, security groups, subnets, route tables, internet gateway, and VPC are absent.

## Failure recovery and cleanup

The experiment harness does not automatically destroy infrastructure after an error; automatic cleanup could hide evidence or target the wrong context. If the harness fails:

1. Stop the probe locally.
2. Re-run `aws-account-guard.sh`.
3. Preserve ignored runtime evidence needed for diagnosis.
4. Run `terraform plan -destroy` using the same P1 state and verify every action has the P1 prefix/tags.
5. Run `terraform destroy` only after that review.
6. Query AWS by all three P1 tags and the `p01-self-healing` prefix to find residual resources.
7. If state is unavailable or account identity is uncertain, do not perform manual deletion; restore the state/identity context first.
