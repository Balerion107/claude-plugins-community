#!/usr/bin/env bash
# Run `claude plugin validate` on the full assembled marketplace.json.
# This is the canonical CLI check — catches anything the schema/invariants miss
# and stays in sync with whatever the CLI itself enforces.

source "$ACTION_PATH/lib/common.sh"

: "${VALIDATE_TMP:?}"
MP="$VALIDATE_TMP/marketplace.json"

group_start "CLI: claude plugin validate (marketplace)"

if ! command -v claude >/dev/null 2>&1; then
  die "claude CLI not found on PATH"
fi

if out="$(claude plugin validate "$MP" 2>&1)"; then
  log "$out"
  if grep -qi "warning" <<<"$out"; then
    if [[ "${FAIL_ON_WARNINGS:-false}" == "true" ]]; then
      error "claude plugin validate reported warnings (fail-on-warnings is set)"
      record_result "cli-marketplace" "fail" "marketplace.json" "$out"
      exit 1
    fi
    warn "claude plugin validate reported warnings"
    record_result "cli-marketplace" "warn" "marketplace.json" "$out"
  else
    record_result "cli-marketplace" "pass" "marketplace.json" ""
  fi
else
  error "claude plugin validate failed"
  log "$out"
  record_result "cli-marketplace" "fail" "marketplace.json" "$out"
  exit 1
fi

group_end
