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

script_dir="$(cd "$(dirname "$0")" && pwd)"
guard="${script_dir}/../../scripts/aws-account-guard.sh"
"$guard"

profile="${AWS_PROFILE:?AWS_PROFILE must name the verified personal P1 profile}"
asg_name="${WEB_ASG_NAME:?WEB_ASG_NAME is required}"
target_group_arn="${WEB_TARGET_GROUP_ARN:?WEB_TARGET_GROUP_ARN is required}"
alb_url="${WEB_ALB_URL:?WEB_ALB_URL is required}"
probe_interval_ms="${PROBE_INTERVAL_MS:-250}"
if ! [[ "$probe_interval_ms" =~ ^[0-9]+$ ]] || (( probe_interval_ms < 50 || probe_interval_ms > 999 )); then
  echo "PROBE_INTERVAL_MS must be an integer between 50 and 999" >&2
  exit 2
fi

region="${AWS_REGION:-ap-northeast-2}"
grafana_url="${P01_GRAFANA_URL:-http://127.0.0.1:33000}"
prometheus_url="${P01_PROMETHEUS_URL:-http://127.0.0.1:39090}"
artifact_dir="${script_dir}/artifacts"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
probe_log="${artifact_dir}/${run_id}-probes.tsv"
stop_file="${artifact_dir}/${run_id}.stop"
summary_file="${artifact_dir}/${run_id}-availability.json"
status_log="${artifact_dir}/${run_id}-aws-status.jsonl"
evidence_file="${artifact_dir}/${run_id}-raw.json"
failure_evidence_file="${artifact_dir}/${run_id}-failure.json"
curated_file="${artifact_dir}/${run_id}-curated.json"
portfolio_file="${artifact_dir}/${run_id}-portfolio.md"
live_state="${artifact_dir}/live-state.json"
probe_pid=""
experiment_complete="no"
failure_reason=""
phase="baseline"
desired=0
in_service=0
healthy_count=0
failure_at=""
detection_at=""
replacement_at=""
replacement_ready_at=""
convergence_at=""
recovery_duration=0
mkdir -p "$artifact_dir"
: >"$status_log"

iso_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
ms_now() { date -u +%s%3N; }
seconds_between() { awk -v start="$1" -v end="$2" 'BEGIN { printf "%.3f", (end-start)/1000 }'; }
epoch_seconds() {
  if [[ -n "$1" ]]; then date -u -d "$1" +%s.%3N; else printf '0'; fi
}

metric_value() {
  curl --fail --silent --get --data-urlencode "query=$1" "${prometheus_url}/api/v1/query" \
    | jq -r '.data.result[0].value[1] // empty'
}

require_dashboard_state() {
  local expected_availability="$1"
  local observed_availability
  curl --fail --silent "${grafana_url}/api/health" >/dev/null
  curl --fail --silent "${grafana_url}/api/dashboards/uid/p01-resilience" >/dev/null
  observed_availability="$(metric_value p1_http_availability_percent)"
  [[ -n "$observed_availability" ]]
  [[ "$expected_availability" == "any" || "$observed_availability" == "$expected_availability" ]]
  [[ "$(metric_value p1_alb_healthy_targets)" == "$healthy_count" ]]
  [[ "$(metric_value p1_asg_inservice_instances)" == "$in_service" ]]
  [[ "$(metric_value p1_asg_desired_capacity)" == "$desired" ]]
}

write_live_state() {
  local temporary="${live_state}.tmp"
  jq -n \
    --arg phase "$phase" --arg probe_file "$(basename "$probe_log")" \
    --argjson desired "$desired" --argjson inservice "$in_service" \
    --argjson healthy "$healthy_count" --argjson duration "$recovery_duration" \
    --argjson failure "$(epoch_seconds "$failure_at")" \
    --argjson detected "$(epoch_seconds "$detection_at")" \
    --argjson replacement "$(epoch_seconds "$replacement_at")" \
    --argjson ready "$(epoch_seconds "$replacement_ready_at")" \
    --argjson convergence "$(epoch_seconds "$convergence_at")" \
    --arg reason "$failure_reason" \
    '{
      schema_version: "1.0", synthetic: false, phase: $phase,
      probe_file: $probe_file, desired_capacity: $desired,
      inservice_instances: $inservice, healthy_targets: $healthy,
      recovery_duration_seconds: $duration,
      events: {
        failure_injected: $failure, failure_detected: $detected,
        replacement_started: $replacement, replacement_healthy: $ready,
        recovery_complete: $convergence
      },
      failure_reason: (if $reason == "" then null else $reason end)
    }' >"$temporary"
  mv "$temporary" "$live_state"
}

record_status() {
  local victim_state="${1:-unknown}"
  local replacement_state="${2:-absent}"
  jq -cn --arg timestamp "$(iso_now)" --arg phase "$phase" \
    --arg victim_state "$victim_state" --arg replacement_state "$replacement_state" \
    --argjson desired "$desired" --argjson inservice "$in_service" --argjson healthy "$healthy_count" \
    '{timestamp:$timestamp,phase:$phase,desired_capacity:$desired,
      inservice_instances:$inservice,healthy_targets:$healthy,
      victim_target_state:$victim_state,replacement_target_state:$replacement_state}' >>"$status_log"
}

wait_for_screenshot() {
  local checkpoint="$1"
  echo "CHECKPOINT_${checkpoint}_READY"
  echo "Type CAPTURED after the requested Grafana and AWS Console screenshots are saved."
  if [[ ! -r /dev/tty ]]; then
    failure_reason="checkpoint_${checkpoint}_requires_interactive_confirmation"
    echo "$failure_reason" >&2
    exit 2
  fi
  local response
  while IFS= read -r response </dev/tty; do
    [[ "$response" == "CAPTURED" ]] && return
    echo "Waiting for exact confirmation: CAPTURED"
  done
  failure_reason="checkpoint_${checkpoint}_confirmation_closed"
  exit 2
}

cleanup() {
  local status=$?
  touch "$stop_file"
  if [[ -n "$probe_pid" ]]; then
    wait "$probe_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$stop_file"
  if [[ "$status" -ne 0 && "$experiment_complete" != "yes" ]]; then
    phase="failed"
    [[ -n "$failure_reason" ]] || failure_reason="experiment_exited_with_status_${status}"
    write_live_state || true
    jq -n --arg run_id "$run_id" --arg reason "$failure_reason" --arg phase "$phase" \
      --arg failure_at "$failure_at" --arg detection_at "$detection_at" \
      --arg replacement_at "$replacement_at" --arg ready_at "$replacement_ready_at" \
      --arg convergence_at "$convergence_at" --arg probe_file "$(basename "$probe_log")" \
      --arg status_file "$(basename "$status_log")" --argjson desired "$desired" \
      --argjson inservice "$in_service" --argjson healthy "$healthy_count" \
      '{schema_version:"1.0",synthetic:false,run_id:$run_id,
        scenario:"aws_asg_instance_termination",outcome:"failed",phase:$phase,
        timeline:{failure_injected_at:$failure_at,alb_failure_detected_at:$detection_at,
          replacement_instance_observed_at:$replacement_at,replacement_target_healthy_at:$ready_at,
          final_capacity_convergence_at:$convergence_at},
        last_observed_capacity:{desired_capacity:$desired,inservice_instances:$inservice,healthy_targets:$healthy},
        raw_artifacts:{http_probes:$probe_file,aws_status_transitions:$status_file},
        failure_reason:$reason}' >"$failure_evidence_file" || true
    echo "failure_reason=${failure_reason}" >&2
    echo "failure_evidence=${failure_evidence_file}" >&2
    echo "raw_status=${status_log}" >&2
  fi
}
trap cleanup EXIT

asg_json="$(aws autoscaling describe-auto-scaling-groups --profile "$profile" --region "$region" \
  --auto-scaling-group-names "$asg_name" --output json)"
desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<<"$asg_json")"
mapfile -t original_instances < <(jq -r '.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService") | .InstanceId' <<<"$asg_json")
in_service="${#original_instances[@]}"
if [[ "$in_service" -ne "$desired" ]]; then
  failure_reason="asg_not_converged_before_injection"
  exit 1
fi

target_json="$(aws elbv2 describe-target-health --profile "$profile" --region "$region" --target-group-arn "$target_group_arn")"
healthy_count="$(jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length' <<<"$target_json")"
if [[ "$healthy_count" -ne "$desired" ]]; then
  failure_reason="target_group_not_healthy_before_injection"
  exit 1
fi

rm -f "$stop_file"
"$script_dir/continuous_probe.sh" "$alb_url" "$probe_log" "$stop_file" "0.$(printf '%03d' "$probe_interval_ms")" &
probe_pid=$!
write_live_state
record_status healthy absent
sleep 10

baseline_total="$(awk 'END {print NR+0}' "$probe_log")"
baseline_failures="$(awk -F '\t' '$3 != 1 {count++} END {print count+0}' "$probe_log")"
if [[ "$baseline_total" -eq 0 || "$baseline_failures" -ne 0 ]]; then
  failure_reason="http_baseline_not_healthy"
  exit 1
fi
if ! require_dashboard_state "100"; then
  failure_reason="grafana_baseline_not_ready"
  exit 1
fi

echo "CHECKPOINT A — Before Failure: ASG ${in_service}/${desired}, ALB healthy ${healthy_count}/${desired}, HTTP ${baseline_total}/${baseline_total}."
echo "Capture the full Grafana dashboard and either Target Group Targets or ASG Instance Management."
wait_for_screenshot A

# The screenshot wait may be long; repeat the account guard immediately before termination.
"$guard"
victim="${original_instances[0]}"
failure_at="$(iso_now)"
failure_ms="$(ms_now)"
aws ec2 terminate-instances --profile "$profile" --region "$region" --instance-ids "$victim" >/dev/null
phase="failure_injected"
write_live_state
record_status healthy absent

replacement_id=""
checkpoint_b_announced="no"
deadline=$(( $(date +%s) + 600 ))

while (( $(date +%s) < deadline )); do
  now="$(iso_now)"
  asg_json="$(aws autoscaling describe-auto-scaling-groups --profile "$profile" --region "$region" \
    --auto-scaling-group-names "$asg_name" --output json)"
  target_json="$(aws elbv2 describe-target-health --profile "$profile" --region "$region" \
    --target-group-arn "$target_group_arn" --output json)"

  victim_state="$(jq -r --arg id "$victim" '.TargetHealthDescriptions[]? | select(.Target.Id == $id) | .TargetHealth.State' <<<"$target_json")"
  if [[ -z "$detection_at" && "$victim_state" != "healthy" ]]; then
    detection_at="$now"
    phase="degraded"
  fi

  for candidate in $(jq -r '.AutoScalingGroups[0].Instances[].InstanceId' <<<"$asg_json"); do
    if [[ "$candidate" != "${original_instances[0]}" && "$candidate" != "${original_instances[1]}" ]]; then
      replacement_id="$candidate"
      if [[ -z "$replacement_at" ]]; then
        replacement_at="$now"
        phase="replacement_started"
      fi
    fi
  done

  replacement_health="absent"
  if [[ -n "$replacement_id" ]]; then
    replacement_health="$(jq -r --arg id "$replacement_id" '.TargetHealthDescriptions[]? | select(.Target.Id == $id) | .TargetHealth.State' <<<"$target_json")"
    [[ -n "$replacement_health" ]] || replacement_health="registering"
    if [[ "$replacement_health" == "healthy" && -z "$replacement_ready_at" ]]; then
      replacement_ready_at="$now"
      phase="replacement_healthy"
    fi
  fi

  in_service="$(jq '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService" and .HealthStatus == "Healthy")] | length' <<<"$asg_json")"
  healthy_count="$(jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length' <<<"$target_json")"
  write_live_state
  record_status "${victim_state:-removed}" "$replacement_health"

  if [[ "$checkpoint_b_announced" == "no" && ( -n "$detection_at" || -n "$replacement_at" ) ]]; then
    checkpoint_b_announced="yes"
    echo "CHECKPOINT_B_READY — phase=${phase}, ASG ${in_service}/${desired}, ALB healthy ${healthy_count}/${desired}; recovery continues without waiting."
    echo "Capture Grafana's degraded interval and Target Group health or ASG Activity/Instance Management now."
  fi

  if [[ -n "$replacement_ready_at" && "$in_service" -eq "$desired" && "$healthy_count" -eq "$desired" ]]; then
    convergence_at="$now"
    convergence_ms="$(ms_now)"
    recovery_duration="$(seconds_between "$failure_ms" "$convergence_ms")"
    phase="recovered"
    write_live_state
    record_status removed healthy
    break
  fi
  sleep 2
done

if [[ -z "$convergence_at" ]]; then
  failure_reason="timeout_waiting_for_asg_target_convergence"
  exit 1
fi
sleep 10
recent_failures="$(tail -n 10 "$probe_log" | awk -F '\t' '$3 != 1 {count++} END {print count+0}')"
if [[ "$recent_failures" -ne 0 ]]; then
  failure_reason="http_not_stable_after_capacity_convergence"
  exit 1
fi
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
  --arg target_group_arn "$target_group_arn" --arg status_file "$(basename "$status_log")" \
  --argjson desired "$desired" --argjson duration "$recovery_duration" \
  '{
    schema_version: "1.0", synthetic: false, run_id: $run_id,
    scenario: "aws_asg_instance_termination",
    failure: {target: $victim, injection: "aws ec2 terminate-instances"},
    pre_failure: {desired_capacity: $desired, inservice_instances: $desired, healthy_targets: $desired},
    post_recovery: {desired_capacity: $desired, inservice_instances: $desired, healthy_targets: $desired},
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
    raw_artifacts: {aws_status_transitions: $status_file},
    aws_state: {auto_scaling_group: $asg_name, target_group_arn: $target_group_arn},
    failure_reason: null
  }' >"$evidence_file"

python3 "$script_dir/curate_evidence.py" "$evidence_file" --status "$status_log" \
  --json-output "$curated_file" --markdown-output "$portfolio_file"

if ! require_dashboard_state "any"; then
  failure_reason="grafana_recovery_state_not_ready"
  exit 1
fi

experiment_complete="yes"
echo "CHECKPOINT C — Recovery Complete: ASG ${in_service}/${desired}, ALB healthy ${healthy_count}/${desired}, HTTP stable."
echo "Capture the final Grafana dashboard and replacement Target/ASG instance state."
echo "raw_evidence=$evidence_file"
echo "curated_candidate=$curated_file"
echo "portfolio_summary=$portfolio_file"
wait_for_screenshot C
