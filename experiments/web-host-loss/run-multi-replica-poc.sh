#!/usr/bin/env bash
set -euo pipefail

for command in docker jq python3; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 2; }
done

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
prefix="availability-${run_id,,}"
network="${prefix}-network"
manager="${prefix}-manager"
workers=("${prefix}-worker-a" "${prefix}-worker-b" "${prefix}-worker-c")
service="web-availability"
dind_image="docker@sha256:dd43b430341a40d88f4f30edb03865daa9d6fa39c9b1da70f27e2a89cec3eae1"
service_image="nginx@sha256:5f979dcfed4ce6461873f087e8c980d6e29b084b9e8776d9704a7e989b5f4898"
probe_interval_ms=100
script_dir="$(cd "$(dirname "$0")" && pwd)"
artifact_dir="${script_dir}/artifacts"
artifact="${artifact_dir}/multi-${run_id}.json"
probe_log="${artifact_dir}/multi-${run_id}-probes.tsv"
summary_file="${artifact_dir}/multi-${run_id}-availability.json"
probe_pid=""
mkdir -p "$artifact_dir"

cleanup() {
  if [[ -n "$probe_pid" ]]; then
    kill "$probe_pid" >/dev/null 2>&1 || true
    wait "$probe_pid" >/dev/null 2>&1 || true
  fi
  docker rm -f "$manager" "${workers[@]}" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

iso_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
ms_now() { date -u +%s%3N; }
seconds_between() { awk -v start="$1" -v end="$2" 'BEGIN { printf "%.3f", (end-start)/1000 }'; }

wait_daemon() {
  local node="$1"
  for _ in $(seq 1 120); do
    docker exec "$node" docker info >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

running_tasks() {
  docker exec "$manager" docker service ps --no-trunc --filter desired-state=running \
    --format '{{.ID}}|{{.Node}}|{{.CurrentState}}' "$service"
}

running_count() {
  running_tasks | awk -F'|' '$3 ~ /^Running/ { count++ } END { print count+0 }'
}

continuous_probe() {
  while true; do
    local epoch timestamp body
    epoch="$(ms_now)"
    timestamp="$(iso_now)"
    if body="$(docker exec "$manager" wget -q -T 1 -O - http://127.0.0.1:8080/ 2>/dev/null)"; then
      printf '%s\t%s\t1\t%s\n' "$epoch" "$timestamp" "$body" >>"$probe_log"
    else
      printf '%s\t%s\t0\t\n' "$epoch" "$timestamp" >>"$probe_log"
    fi
    sleep 0.1
  done
}

echo "[$(iso_now)] starting isolated one-manager/three-worker Swarm"
docker network create "$network" >/dev/null
for node in "$manager" "${workers[@]}"; do
  docker run -d --privileged --network "$network" --name "$node" --hostname "$node" \
    -e DOCKER_TLS_CERTDIR= "$dind_image" >/dev/null
  wait_daemon "$node"
done

manager_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$network\"}}{{.IPAddress}}{{end}}" "$manager")"
docker exec "$manager" docker swarm init --advertise-addr "$manager_ip" >/dev/null
worker_token="$(docker exec "$manager" docker swarm join-token -q worker)"
for worker in "${workers[@]}"; do
  docker exec "$worker" docker swarm join --token "$worker_token" "${manager_ip}:2377" >/dev/null
  docker exec "$worker" docker pull "$service_image" >/dev/null
done

docker exec "$manager" docker service create --quiet \
  --name "$service" --replicas 2 --replicas-max-per-node 1 \
  --constraint node.role==worker --restart-condition any \
  --env 'NODE_HOSTNAME={{.Node.Hostname}}' \
  --publish published=8080,target=80 --entrypoint /bin/sh "$service_image" \
  -c 'printf "%s\n" "$NODE_HOSTNAME" >/usr/share/nginx/html/index.html; exec nginx -g "daemon off;"' \
  >/dev/null

for _ in $(seq 1 180); do
  [[ "$(running_count)" == "2" ]] && break
  sleep 0.5
done
[[ "$(running_count)" == "2" ]] || { echo "initial replicas did not become ready" >&2; exit 1; }

mapfile -t initial_lines < <(running_tasks)
initial_task_ids=()
initial_nodes=()
for line in "${initial_lines[@]}"; do
  IFS='|' read -r task_id node _ <<<"$line"
  initial_task_ids+=("$task_id")
  initial_nodes+=("$node")
done
[[ "${#initial_nodes[@]}" == "2" ]] || { echo "expected two distributed replicas" >&2; exit 1; }
[[ "${initial_nodes[0]}" != "${initial_nodes[1]}" ]] || { echo "replicas were not distributed" >&2; exit 1; }

: >"$probe_log"
continuous_probe &
probe_pid=$!
sleep 3

failure_at="$(iso_now)"
failure_ms="$(ms_now)"
victim="${initial_nodes[0]}"
docker stop --time 0 "$victim" >/dev/null

detection_at=""
detection_ms=""
scheduling_at=""
scheduling_ms=""
ready_at=""
ready_ms=""
convergence_at=""
convergence_ms=""
replacement_node=""
deadline=$(( $(date +%s) + 120 ))

while (( $(date +%s) < deadline )); do
  node_state="$(docker exec "$manager" docker node inspect "$victim" --format '{{.Status.State}}' 2>/dev/null || true)"
  if [[ -z "$detection_at" && "$node_state" != "ready" ]]; then
    detection_at="$(iso_now)"
    detection_ms="$(ms_now)"
  fi

  mapfile -t current_lines < <(running_tasks || true)
  for line in "${current_lines[@]}"; do
    IFS='|' read -r task_id node current_state <<<"$line"
    if [[ "$task_id" != "${initial_task_ids[0]}" && "$task_id" != "${initial_task_ids[1]}" ]]; then
      if [[ -z "$scheduling_at" ]]; then
        scheduling_at="$(iso_now)"
        scheduling_ms="$(ms_now)"
      fi
      if [[ "$current_state" == Running* && -z "$ready_at" ]]; then
        ready_at="$(iso_now)"
        ready_ms="$(ms_now)"
        replacement_node="$node"
      fi
    fi
  done

  if [[ -n "$ready_at" && "$(running_count)" == "2" ]]; then
    convergence_at="$(iso_now)"
    convergence_ms="$(ms_now)"
    break
  fi
  sleep 0.2
done

if [[ -n "$convergence_at" ]]; then
  sleep 3
  outcome="success"
  failure_reason="null"
  total_duration="$(seconds_between "$failure_ms" "$convergence_ms")"
  detection_duration="$(seconds_between "$failure_ms" "$detection_ms")"
  scheduling_duration="$(seconds_between "$scheduling_ms" "$ready_ms")"
else
  convergence_ms="$(ms_now)"
  outcome="failed"
  failure_reason='"timeout_waiting_for_replica_convergence"'
  total_duration="null"
  detection_duration="null"
  scheduling_duration="null"
fi

kill "$probe_pid" >/dev/null 2>&1 || true
wait "$probe_pid" >/dev/null 2>&1 || true
probe_pid=""

python3 "$script_dir/summarize_probes.py" "$probe_log" \
  --failure-ms "$failure_ms" --convergence-ms "$convergence_ms" \
  --interval-ms "$probe_interval_ms" >"$summary_file"

initial_nodes_json="$(printf '%s\n' "${initial_nodes[@]}" | jq -R . | jq -s .)"
jq -n --slurpfile availability "$summary_file" \
  --arg run_id "$run_id" --arg target "$victim" \
  --arg failure_at "$failure_at" --arg detection_at "$detection_at" \
  --arg scheduling_at "$scheduling_at" --arg ready_at "$ready_at" \
  --arg convergence_at "$convergence_at" --arg outcome "$outcome" \
  --arg replacement_node "$replacement_node" --argjson initial_nodes "$initial_nodes_json" \
  --argjson total_duration "$total_duration" --argjson detection_duration "$detection_duration" \
  --argjson scheduling_duration "$scheduling_duration" --argjson failure_reason "$failure_reason" \
  '{
    schema_version: "1.1",
    run_id: $run_id,
    scenario: "multi_replica_host_failure",
    failure: {target: $target, injection: "docker stop worker Docker daemon container"},
    pre_failure: {
      service_responding: true,
      desired_replicas: 2,
      running_replicas: 2,
      workload_node: ($initial_nodes | join(",")),
      active_replica_nodes: $initial_nodes
    },
    timeline: {
      failure_injected_at: $failure_at,
      failure_detected_at: ($detection_at | if length == 0 then null else . end),
      recovery_started_at: ($scheduling_at | if length == 0 then null else . end),
      workload_ready_at: ($ready_at | if length == 0 then null else . end),
      service_recovered_at: ($convergence_at | if length == 0 then null else . end),
      final_replica_convergence_at: ($convergence_at | if length == 0 then null else . end)
    },
    recovery: {
      outcome: $outcome,
      mechanism: "surviving replica serves while Swarm reschedules onto spare worker",
      total_duration_seconds: $total_duration,
      detection_duration_seconds: $detection_duration,
      rescheduling_duration_seconds: $scheduling_duration,
      service_unavailable_observed: ($availability[0].failed_requests > 0),
      original_node: $target,
      new_node: ($replacement_node | if length == 0 then null else . end)
    },
    availability: $availability[0],
    automatic_scope: "traffic routing to survivor and desired replica convergence",
    manual_scope: "failed host repair/rejoin and root-cause remediation",
    failure_reason: $failure_reason
  }' >"$artifact"

echo "evidence=$artifact"
jq . "$artifact"
[[ "$outcome" == "success" ]]
