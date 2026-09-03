#!/usr/bin/env bash
set -euo pipefail

target_group="${1:?target group is required}"
service_name="${2:?service name is required}"
mode="${RECOVERY_MODE:-mock}"

if [[ "$mode" == "mock" ]]; then
  printf '[MOCK] restart service=%s target=%s\n' "$service_name" "$target_group"
  exit 0
fi

if [[ "$mode" != "ansible" ]]; then
  printf '[ERROR] unsupported RECOVERY_MODE=%s\n' "$mode" >&2
  exit 2
fi

inventory="${ANSIBLE_INVENTORY:?ANSIBLE_INVENTORY is required in ansible mode}"
ANSIBLE_HOST_KEY_CHECKING=False ansible "$target_group" -i "$inventory" \
  --become -m ansible.builtin.service -a "name=${service_name} state=restarted"
