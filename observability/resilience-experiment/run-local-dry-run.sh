#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "${script_dir}/../.." && pwd)"
artifact_dir="${repository_root}/experiments/aws-web-host-loss/artifacts"
grafana_port="${P01_GRAFANA_PORT:-33000}"
prometheus_port="${P01_PROMETHEUS_PORT:-39090}"
keep_stack="${KEEP_P01_OBSERVABILITY_STACK:-no}"

cleanup() {
  if [[ "$keep_stack" != "yes" ]]; then
    docker compose --project-directory "$script_dir" -f "$script_dir/docker-compose.yml" down --remove-orphans >/dev/null
  fi
}
trap cleanup EXIT

mkdir -p "$artifact_dir"
docker compose --project-directory "$script_dir" -f "$script_dir/docker-compose.yml" up -d --remove-orphans

for _attempt in $(seq 1 60); do
  if curl --fail --silent "http://127.0.0.1:${grafana_port}/api/health" >/dev/null \
    && curl --fail --silent "http://127.0.0.1:${prometheus_port}/-/ready" >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent "http://127.0.0.1:${grafana_port}/api/health" >/dev/null
curl --fail --silent "http://127.0.0.1:${prometheus_port}/-/ready" >/dev/null

python3 "$script_dir/mock/generate_mock.py" --artifact-dir "$artifact_dir"
sleep 3
python3 "$script_dir/validate_dry_run.py" \
  --grafana-url "http://127.0.0.1:${grafana_port}" \
  --prometheus-url "http://127.0.0.1:${prometheus_port}"

python3 "${repository_root}/experiments/aws-web-host-loss/curate_evidence.py" \
  "$artifact_dir/mock-raw-evidence.json" \
  --status "$artifact_dir/mock-aws-status.jsonl" \
  --json-output "$artifact_dir/mock-curated-evidence.json" \
  --markdown-output "$artifact_dir/mock-portfolio-summary.md"

echo "Synthetic dashboard: http://127.0.0.1:${grafana_port}/d/p01-resilience"
echo "Mock artifacts are Git-ignored under ${artifact_dir}."
if [[ "$keep_stack" == "yes" ]]; then
  echo "The local stack remains running because KEEP_P01_OBSERVABILITY_STACK=yes."
fi
