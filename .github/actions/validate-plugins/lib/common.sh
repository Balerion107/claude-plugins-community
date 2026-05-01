#!/usr/bin/env bash
# Shared helpers for validate-plugins action scripts.
# Source this at the top of every script: source "$ACTION_PATH/lib/common.sh"

set -euo pipefail

# ---- logging ---------------------------------------------------------------

log()   { printf '%s\n' "$*"; }
info()  { printf '::notice::%s\n' "$*"; }
warn()  { printf '::warning::%s\n' "$*"; }
error() { printf '::error::%s\n' "$*"; }
die()   { error "$*"; exit 1; }

group_start() { printf '::group::%s\n' "$*"; }
group_end()   { printf '::endgroup::\n'; }

# ---- result tracking -------------------------------------------------------
# Scripts append findings here; 90-report.sh reads it.

RESULTS_FILE="${VALIDATE_TMP:-./.validate-tmp}/results.jsonl"

record_result() {
  local step="$1" status="$2" subject="$3" detail="${4:-}"
  mkdir -p "$(dirname "$RESULTS_FILE")"
  jq -cn \
    --arg step "$step" \
    --arg status "$status" \
    --arg subject "$subject" \
    --arg detail "$detail" \
    '{step:$step, status:$status, subject:$subject, detail:$detail}' \
    >> "$RESULTS_FILE"
}

# ---- safety assertions -----------------------------------------------------

# Reject any string containing shell metacharacters or whitespace.
# Defense-in-depth on top of schema regex enforcement.
assert_safe_string() {
  local label="$1" value="$2"
  case "$value" in
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'('*|*')'*|*'<'*|*'>'*|*' '*|*'	'*|*'"'*|*"'"*|*'\'*)
      die "$label contains unsafe characters: $value"
      ;;
  esac
}

# URL must be https://<allowed-host>/<safe-chars> only.
# Host must be in ALLOWED_HOSTS (space-separated) and must not be a bare IP.
# SSRF guard: prevents cloning from metadata endpoints / internal ranges.
assert_safe_url() {
  local url="$1"
  assert_safe_string "url" "$url"
  if [[ ! "$url" =~ ^https://[A-Za-z0-9./_-]+$ ]]; then
    die "url does not match ^https://[A-Za-z0-9./_-]+\$ : $url"
  fi
  local host="${url#https://}"
  host="${host%%/*}"
  if [[ "$host" =~ ^[0-9.]+$ ]] || [[ "$host" =~ : ]]; then
    die "url host is a bare IP address (not permitted): $host"
  fi
  local allowed="${ALLOWED_HOSTS:-github.com gitlab.com bitbucket.org}"
  local ok=""
  for h in $allowed; do
    if [[ "$host" == "$h" ]] || [[ "$host" == *".$h" ]]; then
      ok=1; break
    fi
  done
  if [[ -z "$ok" ]]; then
    die "url host '$host' is not in the allowlist ($allowed)"
  fi
}

# SHA must be exactly 40 lowercase hex.
assert_safe_sha() {
  local sha="$1"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    die "sha is not a 40-char lowercase hex string: $sha"
  fi
}

# Path must be relative, no .., safe chars only.
assert_safe_path() {
  local p="$1"
  assert_safe_string "path" "$p"
  if [[ "$p" == /* ]] || [[ "$p" == *".."* ]]; then
    die "path is absolute or contains '..': $p"
  fi
}

# ---- jq helpers ------------------------------------------------------------

# Read .plugins[] from a marketplace file as compact JSON lines.
mp_entries() {
  local file="$1"
  jq -c '.plugins[]' -- "$file"
}

# Extract a field from a single-entry JSON string.
entry_field() {
  local entry="$1" field="$2"
  jq -r --arg f "$field" '.[$f] // empty' <<<"$entry"
}
