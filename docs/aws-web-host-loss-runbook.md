# AWS Web Host Loss experiment runbook

## Hard isolation gates

1. Use only the `default` CLI profile that the owner independently matched to the personal account in the AWS Console. Never use an integration-project profile for P1.
2. Set the expected personal account ID only in the shell environment or ignored tfvars. Obtain it from the independently verified Console record, not by assigning the STS output back as the expectation.
3. Run the account guard and stop on any mismatch.
4. Use region `ap-northeast-2` unless a new estimate/plan explicitly approves another region.
5. Confirm the P1 state path is `infra/terraform/state/p01-self-healing.tfstate` and the integration project state is elsewhere.
6. Confirm plan actions contain create only and no existing ID is imported or referenced.
7. Confirm all taggable resources inherit `Project=01-aws-self-healing`, `Owner=KTCLIF`, `Purpose=portfolio-resilience-test` and names use `p01-self-healing`.
8. Start the tracked local dashboard stack and confirm that it has no AWS credential mount or CloudWatch datasource.

```bash
export AWS_PROFILE=default
export ALLOW_DEFAULT_PROFILE_FOR_P1=yes
export P1_EXPECTED_ACCOUNT_ID='<personal account ID>'
export P1_EXPECTED_REGION=ap-northeast-2

aws sts get-caller-identity --profile default
# Manually compare Account with the independently recorded personal account ID.
./scripts/aws-account-guard.sh

export TF_VAR_aws_profile="$AWS_PROFILE"
export TF_VAR_expected_account_id="$P1_EXPECTED_ACCOUNT_ID"
```

Do not paste the account ID into tracked files or command examples.

## Local dashboard preflight

Run the synthetic timeline before AWS apply:

```bash
make resilience-dashboard-dry-run
```

The dry run shuts its containers down by default. For the actual experiment, start a fresh stack with no mock Prometheus history:

```bash
make resilience-dashboard-up
```

Open `http://127.0.0.1:33000/d/p01-resilience`. The synthetic run must visibly say so in its generated summary and must never be presented as AWS evidence. `resilience-dashboard-up` recreates the ephemeral Prometheus storage and removes only the stale live state; the raw mock artifacts remain ignored for troubleshooting. When the AWS harness begins it writes `synthetic=false` state.

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

1. Immediately before apply, run `aws sts get-caller-identity --profile default`, manually compare the account, run the account guard, then run `terraform init -reconfigure` and `terraform plan`. Review create-only actions before explicitly approving `terraform apply`.
2. Wait for ASG `2/2 InService` and ALB target group `2/2 healthy`.
3. Export `WEB_ASG_NAME`, `WEB_TARGET_GROUP_ARN`, and `WEB_ALB_URL` from Terraform outputs.
4. Start the continuous HTTP probe through `run-experiment.sh`; it records a 10-second baseline before failure.
5. The harness selects one current `InService` instance explicitly and records its ID only in ignored runtime evidence.
6. Immediately before destructive injection, repeat `aws sts get-caller-identity --profile default`, the manual account comparison, and the account guard. Set `EXECUTE_AWS_HOST_LOSS=yes` only after verifying the selected account/profile/region and target.
7. The harness re-runs the account guard with the explicit profile, then terminates that instance.
8. Record victim ALB target transition away from `healthy`.
9. Record the first replacement instance observed in the ASG.
10. Wait for the replacement target to become `healthy`.
11. Require ASG `2/2 InService` and ALB `2/2 healthy`, then collect a 10-second post-recovery probe window.
12. Stop the probe and generate ignored JSON/TSV evidence.
13. Run `terraform destroy` with the same guarded profile, account, region, variables, and P1 state.
14. Verify P1-tagged EC2, EBS, ALB, target group, ASG, launch template, security groups, subnets, route tables, internet gateway, and VPC are absent.

## Screenshot checkpoints

### A — Before Failure (blocking)

The harness first verifies ASG `2/2`, ALB healthy `2/2`, and a failure-free HTTP baseline. It then prints `CHECKPOINT_A_READY` and waits for the exact input `CAPTURED`. Capture:

- Grafana: full dashboard, with Summary and baseline sections visible.
- AWS Console: Target Group **Targets** showing two healthy targets, or ASG **Instance management** showing two InService instances.
- Values that must be legible: HTTP availability, healthy target count, InService/desired capacity, and baseline time range.

No termination occurs before confirmation. Because the wait is before failure injection, it is excluded from recovery timing.

### B — Failure / Replacement (non-blocking)

When target degradation or replacement first appears, the harness prints `CHECKPOINT_B_READY` with current ALB/ASG state. Polling, HTTP probes, ASG replacement, and timers continue without waiting. Capture as soon as notified:

- Grafana: HTTP failure/degraded interval and the capacity/event panels.
- AWS Console: Target Group target health transition and ASG **Activity** or **Instance management** showing termination/replacement.
- Values that matter: healthy target reduction, current InService/desired values, new instance lifecycle state, and timestamps.

The transient AWS Console state may recover before a screenshot is taken; machine evidence is authoritative and is never delayed for this checkpoint.

### C — Recovery Complete (blocking before destroy)

After ASG `2/2`, ALB healthy `2/2`, replacement health, stable HTTP probes, and evidence generation, the harness prints the evidence paths and `CHECKPOINT_C_READY`. Capture:

- Grafana: full 15-minute dashboard showing baseline → failure → recovery.
- AWS Console: two healthy Target Group targets and the replacement instance in ASG Instance Management.
- Values that must be legible: final capacity, recovery duration, availability/error interval, and completed events.

Type `CAPTURED` after screenshots are saved. Destroy is a separate guarded step and begins only after this confirmation.

## Screenshot publication classification

| Visible item | Classification | Handling |
|---|---|---|
| Health/counts, timestamps, AZ names, generic P1 tags | 그대로 공개 가능 | Review unrelated browser chrome first |
| Instance ID, public/private IP, ALB DNS, target group/ASG names | 마스킹 권장 | Mask unless needed for a private review; counts should remain visible |
| ARN without account component | 마스킹 권장 | Prefer masking the entire ARN |
| AWS Account ID, ARN account component, IAM user/role identity | 반드시 마스킹 | Do not publish |
| Console sign-in URL, access token, credential, billing/contact identity | 반드시 마스킹 | Do not save or publish if avoidable |

Screenshots are never automatically copied into or committed to this repository.

## Evidence outputs

- Machine evidence, ignored: probe TSV, availability JSON, two-second AWS status JSONL, raw evidence JSON, live dashboard state.
- Curated candidate, ignored until human review: identifier-free JSON with ordered events, duration metrics, request/error metrics, and capacity transitions.
- Portfolio summary, ignored until human review: Markdown timeline and 3–5 headline measurements.
- Public evidence: copy only the reviewed curated files into `docs/evidence/`; never copy raw artifacts.

## Failure recovery and cleanup

The experiment harness does not automatically destroy infrastructure after an error; automatic cleanup could hide evidence or target the wrong context. If the harness fails:

1. Stop the probe locally.
2. Re-run `aws-account-guard.sh`.
3. Preserve ignored runtime evidence needed for diagnosis.
4. Run `terraform plan -destroy` using the same P1 state and verify every action has the P1 prefix/tags.
5. Run `terraform destroy` only after that review.
6. Query AWS by all three P1 tags and the `p01-self-healing` prefix to find residual resources.
7. If state is unavailable or account identity is uncertain, do not perform manual deletion; restore the state/identity context first.
