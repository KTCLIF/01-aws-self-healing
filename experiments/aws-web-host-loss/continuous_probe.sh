#!/usr/bin/env bash
set -euo pipefail

url="${1:?usage: continuous_probe.sh URL OUTPUT_TSV STOP_FILE [INTERVAL_SECONDS]}"
output="${2:?output TSV is required}"
stop_file="${3:?stop file is required}"
interval="${4:-0.25}"

: >"$output"
while [[ ! -e "$stop_file" ]]; do
  epoch_ms="$(date -u +%s%3N)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  response_file="$(mktemp)"
  if status="$(curl --silent --show-error --max-time 2 --output "$response_file" --write-out '%{http_code}' "$url")" \
      && [[ "$status" == "200" ]]; then
    instance_id="$(jq -r '.instance_id // "unknown"' "$response_file" 2>/dev/null || printf unknown)"
    printf '%s\t%s\t1\t%s\n' "$epoch_ms" "$timestamp" "$instance_id" >>"$output"
  else
    printf '%s\t%s\t0\t\n' "$epoch_ms" "$timestamp" >>"$output"
  fi
  rm -f "$response_file"
  sleep "$interval"
done
