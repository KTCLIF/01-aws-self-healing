#!/usr/bin/env bash
set -euo pipefail

scenario="${1:-host}"
if [[ "$scenario" != "process" && "$scenario" != "host" ]]; then
  echo "usage: $0 [process|host]" >&2
  exit 2
fi

for command in docker jq; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 2; }
done

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
prefix="resilience-${run_id,,}"
network="${prefix}-network"
manager="${prefix}-manager"
worker_a="${prefix}-worker-a"
worker_b="${prefix}-worker-b"
service="web-host-loss"
dind_image="docker@sha256:dd43b430341a40d88f4f30edb03865daa9d6fa39c9b1da70f27e2a89cec3eae1"
service_image="nginx@sha256:5f979dcfed4ce6461873f087e8c980d6e29b084b9e8776d9704a7e989b5f4898"
artifact_dir="$(cd "$(dirname "$0")" && pwd)/artifacts"
artifact="${artifact_dir}/${scenario}-${run_id}.json"
mkdir -p "$artifact_dir"

cleanup() {
  docker rm -f "$manager" "$worker_a" "$worker_b" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

iso_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
ms_now() { date -u +%s%3N; }
seconds_between() { awk -v start="$1" -v end="$2" 'BEGIN { printf "%.3f", (end-start)/1000 }'; }

wait_outer_daemon() {
  local node="$1"
  for _ in $(seq 1 120); do
    if docker exec "$node" docker info >/dev/null 2>&1; then return 0; fi
    sleep 0.25
  done
  return 1
}

service_responds() {
  docker exec "$manager" wget -q -T 1 -O /dev/null http://127.0.0.1:8080/ 2>/dev/null
}

running_task_line() {
  docker exec "$manager" docker service ps --no-trunc \
    --filter desired-state=running --format '{{.ID}}|{{.Node}}|{{.CurrentState}}' "$service" \
    | head -n 1
}

echo "[$(iso_now)] starting isolated three-node Docker-in-Docker Swarm"
docker network create "$network" >/dev/null
for node in "$manager" "$worker_a" "$worker_b"; do
  docker run -d --privileged --network "$network" --name "$node" --hostname "$node" \
    -e DOCKER_TLS_CERTDIR= "$dind_image" >/dev/null
  wait_outer_daemon "$node"
done

manager_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$network\"}}{{.IPAddress}}{{end}}" "$manager")"
docker exec "$manager" docker swarm init --advertise-addr "$manager_ip" >/dev/null
worker_token="$(docker exec "$manager" docker swarm join-token -q worker)"
docker exec "$worker_a" docker swarm join --token "$worker_token" "${manager_ip}:2377" >/dev/null
docker exec "$worker_b" docker swarm join --token "$worker_token" "${manager_ip}:2377" >/dev/null

docker exec "$manager" docker service create --quiet \
  --name "$service" --replicas 1 --constraint node.role==worker \
  --restart-condition any --publish published=8080,target=80 \
  "$service_image" >/dev/null

initial_line=""
for _ in $(seq 1 180); do
  initial_line="$(running_task_line || true)"
  if [[ "$initial_line" == *"Running"* ]] && service_responds; then break; fi
  sleep 0.5
done
if [[ "$initial_line" != *"Running"* ]] || ! service_responds; then
  echo "service did not become ready before failure injection" >&2
  exit 1
fi

IFS='|' read -r initial_task initial_node _ <<<"$initial_line"
initial_outer="$initial_node"
precheck_at="$(iso_now)"
failure_at="$(iso_now)"
failure_ms="$(ms_now)"

if [[ "$scenario" == "process" ]]; then
  task_container="$(docker exec "$initial_outer" docker ps -q --filter label=com.docker.swarm.service.name="$service" | head -n 1)"
  docker exec "$initial_outer" docker kill "$task_container" >/dev/null
  scenario_name="process_failure"
  injection="docker kill workload container; host remains healthy"
  mechanism="Docker Swarm restarts desired task on an available worker"
else
  docker stop --time 0 "$initial_outer" >/dev/null
  scenario_name="host_failure"
  injection="docker stop worker Docker daemon container"
  mechanism="Docker Swarm detects node loss and reschedules desired task to surviving worker"
fi

detection_at=""
detection_ms=""
recovery_start_at=""
recovery_start_ms=""
ready_at=""
ready_ms=""
recovered_at=""
recovered_ms=""
new_node=""
unavailable=false
deadline=$(( $(date +%s) + 120 ))

while (( $(date +%s) < deadline )); do
  current_line="$(running_task_line || true)"
  IFS='|' read -r current_task current_node current_state <<<"$current_line"

  if [[ -z "$detection_at" && "$current_task" != "$initial_task" ]]; then
    detection_at="$(iso_now)"
    detection_ms="$(ms_now)"
  fi
  if [[ -z "$recovery_start_at" && -n "$current_task" && "$current_task" != "$initial_task" ]]; then
    recovery_start_at="$(iso_now)"
    recovery_start_ms="$(ms_now)"
  fi
  if ! service_responds; then unavailable=true; fi
  if [[ -n "$current_task" && "$current_task" != "$initial_task" && "$current_state" == Running* ]]; then
    if [[ -z "$ready_at" ]]; then
      ready_at="$(iso_now)"
      ready_ms="$(ms_now)"
      new_node="$current_node"
    fi
    if service_responds; then
      recovered_at="$(iso_now)"
      recovered_ms="$(ms_now)"
      break
    fi
  fi
  sleep 0.2
done

if [[ -n "$recovered_at" ]]; then
  outcome="success"
  failure_reason="null"
  total_duration="$(seconds_between "$failure_ms" "$recovered_ms")"
  detection_duration="$(seconds_between "$failure_ms" "$detection_ms")"
  rescheduling_duration="$(seconds_between "$recovery_start_ms" "$ready_ms")"
else
  outcome="failed"
  failure_reason='"timeout_waiting_for_ready_workload_and_service_response"'
  total_duration="null"
  detection_duration="null"
  rescheduling_duration="null"
fi

jq -n \
  --arg run_id "$run_id" --arg scenario "$scenario_name" \
  --arg target "$initial_node" --arg injection "$injection" \
  --arg precheck_at "$precheck_at" --arg failure_at "$failure_at" \
  --arg detection_at "$detection_at" --arg recovery_start_at "$recovery_start_at" \
  --arg ready_at "$ready_at" --arg recovered_at "$recovered_at" \
  --arg outcome "$outcome" --arg mechanism "$mechanism" \
  --arg original_node "$initial_node" --arg new_node "$new_node" \
  --argjson unavailable "$unavailable" --argjson failure_reason "$failure_reason" \
  --argjson total_duration "$total_duration" --argjson detection_duration "$detection_duration" \
  --argjson rescheduling_duration "$rescheduling_duration" \
  '{
    schema_version: "1.0",
    run_id: $run_id,
    scenario: $scenario,
    failure: {target: $target, injection: $injection},
    pre_failure: {
      checked_at: $precheck_at,
      service_responding: true,
      desired_replicas: 1,
      running_replicas: 1,
      workload_node: $original_node
    },
    timeline: {
      failure_injected_at: $failure_at,
      failure_detected_at: ($detection_at | if length == 0 then null else . end),
      recovery_started_at: ($recovery_start_at | if length == 0 then null else . end),
      workload_ready_at: ($ready_at | if length == 0 then null else . end),
      service_recovered_at: ($recovered_at | if length == 0 then null else . end)
    },
    recovery: {
      outcome: $outcome,
      mechanism: $mechanism,
      total_duration_seconds: $total_duration,
      detection_duration_seconds: $detection_duration,
      rescheduling_duration_seconds: $rescheduling_duration,
      service_unavailable_observed: $unavailable,
      original_node: $original_node,
      new_node: ($new_node | if length == 0 then null else . end)
    },
    automatic_scope: "task replacement and routing-mesh service restoration",
    manual_scope: "failed host repair/rejoin and root-cause remediation",
    failure_reason: $failure_reason
  }' >"$artifact"

echo "evidence=$artifact"
jq . "$artifact"
[[ "$outcome" == "success" ]]
