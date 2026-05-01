#!/usr/bin/env bash
# For each CHANGED external entry: clone at the pinned SHA into an isolated
# temp dir and run `claude plugin validate` against it.
#
# Security: url/sha/path are re-validated here with assert_safe_* before any
# shell use, all interpolations are double-quoted, and `--` end-of-options
# markers are used on every git invocation. Nothing from the cloned repo is
# ever executed; `claude plugin validate` is a static check.

source "$ACTION_PATH/lib/common.sh"

: "${VALIDATE_TMP:?}"
CHANGES="$VALIDATE_TMP/changes.json"
MP="$VALIDATE_TMP/marketplace.json"
TIMEOUT_SECS="${EXTERNAL_TIMEOUT_SECS:-120}"

group_start "CLI: claude plugin validate (external plugins)"

if [[ "${VALIDATE_ALL_EXTERNAL:-false}" == "true" ]]; then
  log "validate-all-external is set: scanning every external entry"
  jq -c '[.plugins[] | select(.source|type=="object") | {name, source}]' -- "$MP" \
    > "$VALIDATE_TMP/external-targets.json"
else
  jq -c '.external' -- "$CHANGES" > "$VALIDATE_TMP/external-targets.json"
fi

count="$(jq 'length' -- "$VALIDATE_TMP/external-targets.json")"
if [[ "$count" -eq 0 ]]; then
  log "No external entries to validate; skipping."
  record_result "cli-external" "skip" "summary" "no external entries"
  group_end
  exit 0
fi

failures=0
idx=0
workroot="$(mktemp -d)"
trap 'rm -rf "$workroot"' EXIT

while IFS= read -r ext; do
  idx=$((idx+1))
  name="$(jq -r '.name' <<<"$ext")"
  kind="$(jq -r '.source.source // "unknown"' <<<"$ext")"
  url="$(jq -r '.source.url // .source.repo // empty' <<<"$ext")"
  sha="$(jq -r '.source.sha // empty' <<<"$ext")"
  subdir="$(jq -r '.source.path // ""' <<<"$ext")"

  log "---- $name ($kind) ----"

  if [[ -z "$url" ]]; then
    error "$name: no url/repo field on source"
    record_result "cli-external" "fail" "$name" "no url/repo on source"
    failures=$((failures+1))
    continue
  fi
  if [[ -z "$sha" ]]; then
    error "$name: no sha pin (cannot safely clone)"
    record_result "cli-external" "fail" "$name" "no sha pin"
    failures=$((failures+1))
    continue
  fi

  # Expand owner/repo shorthand (and {source:'github', repo}) to a full https URL.
  if [[ "$url" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    url="https://github.com/$url"
  fi

  # Defense-in-depth: re-assert safety even though schema + I4/I5/I9 already ran.
  assert_safe_url "$url"
  assert_safe_sha "$sha"
  [[ -z "$subdir" ]] || assert_safe_path "$subdir"

  dest="$workroot/ext-$idx"
  mkdir -p -- "$dest"

  if ! timeout "$TIMEOUT_SECS" git clone --quiet --depth 1 -- "$url" "$dest" 2>&1; then
    error "$name: git clone failed or timed out"
    record_result "cli-external" "fail" "$name" "git clone failed"
    failures=$((failures+1))
    continue
  fi

  if ! git -C "$dest" fetch --quiet --depth 1 origin -- "$sha" 2>&1; then
    error "$name: git fetch $sha failed"
    record_result "cli-external" "fail" "$name" "git fetch of pinned sha failed"
    failures=$((failures+1))
    continue
  fi

  if ! git -C "$dest" -c advice.detachedHead=false checkout --quiet "$sha" -- 2>&1; then
    error "$name: git checkout $sha failed"
    record_result "cli-external" "fail" "$name" "git checkout of pinned sha failed"
    failures=$((failures+1))
    continue
  fi

  target="$dest"
  if [[ -n "$subdir" ]]; then
    target="$dest/$subdir"
    if [[ ! -d "$target" ]]; then
      error "$name: subdir '$subdir' not found in repo"
      record_result "cli-external" "fail" "$name" "subdir not found"
      failures=$((failures+1))
      continue
    fi
  fi

  if [[ ! -f "$target/.claude-plugin/plugin.json" ]]; then
    error "$name: no .claude-plugin/plugin.json at $target"
    record_result "cli-external" "fail" "$name" "missing .claude-plugin/plugin.json"
    failures=$((failures+1))
    continue
  fi

  if out="$(timeout "$TIMEOUT_SECS" claude plugin validate "$target/.claude-plugin/plugin.json" 2>&1)"; then
    log "  ✓ $name OK"
    record_result "cli-external" "pass" "$name" ""
  else
    error "$name: claude plugin validate failed"
    log "$out"
    record_result "cli-external" "fail" "$name" "$out"
    failures=$((failures+1))
  fi

  rm -rf -- "$dest"
done < <(jq -c '.[]' -- "$VALIDATE_TMP/external-targets.json")

if (( failures > 0 )); then
  die "$failures external plugin(s) failed validation"
fi

log "All $count changed external plugin(s) validated OK"
group_end
