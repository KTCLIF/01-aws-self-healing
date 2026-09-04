#!/usr/bin/env bash
set -euo pipefail

if [[ "${EXECUTE_AWS_HOST_LOSS:-}" != "yes" ]]; then
  echo "Refusing to terminate an AWS instance." >&2
  echo "Set EXECUTE_AWS_HOST_LOSS=yes only after cost/scope approval." >&2
  exit 2
fi

for command in aws curl jq python3; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 2; }
done

asg_name="${WEB_ASG_NAME:?WEB_ASG_NAME is required}"
target_group_arn="${WEB_TARGET_GROUP_ARN:?WEB_TARGET_GROUP_ARN is required}"
alb_url="${WEB_ALB_URL:?WEB_ALB_URL is required}"
probe_interval_ms="${PROBE_INTERVAL_MS:-250}"
if ! [[ "$probe_interval_ms" =~ ^[0-9]+$ ]] || (( probe_interval_ms < 50 || probe_interval_ms > 999 )); then
  echo "PROBE_INTERVAL_MS must be an integer between 50 and 999" >&2
  exit 2
fi
region="${AWS_REGION:-ap-northeast-2}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
artifact_dir="${script_dir}/artifacts"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
probe_log="${artifact_dir}/${run_id}-probes.tsv"
stop_file="${artifact_dir}/${run_id}.stop"
summary_file="${artifact_dir}/${run_id}-availability.json"
evidence_file="${artifact_dir}/${run_id}.json"
probe_pid=""
mkdir -p "$artifact_dir"

cleanup() {
  touch "$stop_file"
  if [[ -n "$probe_pid" ]]; then
    wait "$probe_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$stop_file"
}
trap cleanup EXIT

iso_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
ms_now() { date -u +%s%3N; }
seconds_between() { awk -v start="$1" -v end="$2" 'BEGIN { printf "%.3f", (end-start)/1000 }'; }

asg_json="$(aws autoscaling describe-auto-scaling-groups --region "$region" \
  --auto-scaling-group-names "$asg_name" --output json)"
desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<<"$asg_json")"
mapfile -t original_instances < <(jq -r '.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService") | .InstanceId' <<<"$asg_json")
[[ "${#original_instances[@]}" -eq "$desired" ]] || { echo "ASG is not converged before injection" >&2; exit 1; }

target_json="$(aws elbv2 describe-target-health --region "$region" --target-group-arn "$target_group_arn")"
healthy_count="$(jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length' <<<"$target_json")"
[[ "$healthy_count" -eq "$desired" ]] || { echo "target group is not healthy before injection" >&2; exit 1; }

rm -f "$stop_file"
"$script_dir/continuous_probe.sh" "$alb_url" "$probe_log" "$stop_file" "0.$(printf '%03d' "$probe_interval_ms")" &
probe_pid=$!
sleep 10

victim="${original_instances[0]}"
failure_at="$(iso_now)"
failure_ms="$(ms_now)"
aws ec2 terminate-instances --region "$region" --instance-ids "$victim" >/dev/null

detection_at=""
replacement_at=""
replacement_ready_at=""
convergence_at=""
replacement_id=""
deadline=$(( $(date +%s) + 600 ))

while (( $(date +%s) < deadline )); do
  now="$(iso_now)"
  asg_json="$(aws autoscaling describe-auto-scaling-groups --region "$region" \
    --auto-scaling-group-names "$asg_name" --output json)"
  target_json="$(aws elbv2 describe-target-health --region "$region" \
    --target-group-arn "$target_group_arn" --output json)"

  victim_state="$(jq -r --arg id "$victim" '.TargetHealthDescriptions[]? | select(.Target.Id == $id) | .TargetHealth.State' <<<"$target_json")"
  if [[ -z "$detection_at" && "$victim_state" != "healthy" ]]; then detection_at="$now"; fi

  for candidate in $(jq -r '.AutoScalingGroups[0].Instances[].InstanceId' <<<"$asg_json"); do
    if [[ "$candidate" != "${original_instances[0]}" && "$candidate" != "${original_instances[1]}" ]]; then
      replacement_id="$candidate"
      [[ -n "$replacement_at" ]] || replacement_at="$now"
    fi
  done

  if [[ -n "$replacement_id" ]]; then
    replacement_health="$(jq -r --arg id "$replacement_id" '.TargetHealthDescriptions[]? | select(.Target.Id == $id) | .TargetHealth.State' <<<"$target_json")"
    if [[ "$replacement_health" == "healthy" && -z "$replacement_ready_at" ]]; then replacement_ready_at="$now"; fi
  fi

  in_service="$(jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService" and .HealthStatus == "Healthy")] | length' <<<"$asg_json")"
  healthy_count="$(jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length' <<<"$target_json")"
  if [[ -n "$replacement_ready_at" && "$in_service" -eq "$desired" && "$healthy_count" -eq "$desired" ]]; then
    convergence_at="$now"
    convergence_ms="$(ms_now)"
    break
  fi
  sleep 2
done

[[ -n "$convergence_at" ]] || { echo "timeout waiting for ASG/target convergence" >&2; exit 1; }
sleep 10
touch "$stop_file"
wait "$probe_pid" || true
probe_pid=""

python3 "$script_dir/../web-host-loss/summarize_probes.py" "$probe_log" \
  --failure-ms "$failure_ms" --convergence-ms "$convergence_ms" \
  --interval-ms "$probe_interval_ms" >"$summary_file"

jq -n --slurpfile availability "$summary_file" \
  --arg run_id "$run_id" --arg victim "$victim" --arg replacement "$replacement_id" \
  --arg failure_at "$failure_at" --arg detection_at "$detection_at" \
  --arg replacement_at "$replacement_at" --arg ready_at "$replacement_ready_at" \
  --arg convergence_at "$convergence_at" --arg asg_name "$asg_name" \
  --arg target_group_arn "$target_group_arn" --argjson desired "$desired" \
  --argjson duration "$(seconds_between "$failure_ms" "$convergence_ms")" \
  '{
    schema_version: "1.0",
    run_id: $run_id,
    scenario: "aws_asg_instance_termination",
    failure: {target: $victim, injection: "aws ec2 terminate-instances"},
    pre_failure: {desired_capacity: $desired, healthy_targets: $desired},
    timeline: {
      failure_injected_at: $failure_at,
      alb_failure_detected_at: $detection_at,
      replacement_instance_observed_at: $replacement_at,
      replacement_target_healthy_at: $ready_at,
      final_capacity_convergence_at: $convergence_at
    },
    recovery: {
      outcome: "success",
      mechanism: "ALB healthy-target routing and ASG desired-capacity replacement",
      total_duration_seconds: $duration,
      original_instance: $victim,
      replacement_instance: $replacement
    },
    availability: $availability[0],
    aws_state: {auto_scaling_group: $asg_name, target_group_arn: $target_group_arn},
    failure_reason: null
  }' >"$evidence_file"

echo "evidence=$evidence_file"
jq . "$evidence_file"
