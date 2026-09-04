#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:?AWS_PROFILE must name the dedicated P1 profile}"
expected_account="${P1_EXPECTED_ACCOUNT_ID:?P1_EXPECTED_ACCOUNT_ID must be supplied securely}"
expected_region="${P1_EXPECTED_REGION:-ap-northeast-2}"

if [[ "$profile" == "default" && "${ALLOW_DEFAULT_PROFILE_FOR_P1:-}" != "yes" ]]; then
  echo "Refusing the default profile. Use a dedicated personal-account profile." >&2
  echo "Set ALLOW_DEFAULT_PROFILE_FOR_P1=yes only after independently verifying ownership." >&2
  exit 2
fi

if ! [[ "$expected_account" =~ ^[0-9]{12}$ ]]; then
  echo "P1_EXPECTED_ACCOUNT_ID must be a 12-digit account ID." >&2
  exit 2
fi

actual_account="$(aws sts get-caller-identity --profile "$profile" --query Account --output text)"
if [[ "$actual_account" != "$expected_account" ]]; then
  echo "AWS account mismatch; P1 operation refused." >&2
  exit 3
fi

configured_region="$(aws configure get region --profile "$profile")"
effective_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$configured_region}}"
if [[ "$effective_region" != "$expected_region" ]]; then
  echo "AWS region mismatch; expected ${expected_region}, got ${effective_region}." >&2
  exit 4
fi

echo "P1 account guard passed for profile=${profile}, region=${effective_region}; account ID not displayed."
