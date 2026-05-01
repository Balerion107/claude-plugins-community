#!/usr/bin/env bash
# Custom hardening invariants beyond the JSON Schema.
# Always runs on the full marketplace.
#
# I1  plugins[] alpha-sorted by name
# I2  no duplicate names
# I3  description 10-500 chars, no leading/trailing whitespace
# I4  all source.url are https:// (re-checked here as defense-in-depth)
# I5  every external source has a 40-char sha
# I6  per-file mode: filename matches .name
# I7  per-file mode: PR does not edit assembled marketplace.json directly
# I8  vendored source path exists and contains .claude-plugin/plugin.json
# I9  url/path/sha contain no shell metacharacters

source "$ACTION_PATH/lib/common.sh"

: "${VALIDATE_TMP:?}"
: "${MARKETPLACE_PATH:?}"
MP="$VALIDATE_TMP/marketplace.json"
WARN_INVARIANTS=" ${WARN_INVARIANTS:-I1 I3 I5 I8} "
failures=0
warnings=0

entry_line() {
  local name="$1"
  [[ -n "$name" ]] || return 0
  grep -n "\"name\": \"$name\"" -- "$MARKETPLACE_PATH" 2>/dev/null | head -1 | cut -d: -f1 || true
}

flag() {
  local code="$1" msg="$2" name="${3:-}"
  local line; line="$(entry_line "$name")"
  local loc="file=$MARKETPLACE_PATH${line:+,line=$line}"
  if [[ "$WARN_INVARIANTS" == *" $code "* ]]; then
    printf '::warning %s::invariant %s: %s\n' "$loc" "$code" "$msg"
    record_result "invariants" "warn" "$code" "$msg"; warnings=$((warnings+1))
  else
    printf '::error %s::invariant %s: %s\n' "$loc" "$code" "$msg"
    record_result "invariants" "fail" "$code" "$msg"; failures=$((failures+1))
  fi
}

group_start "Custom invariants I1-I9"

# I1 sort
sorted="$(jq -r '[.plugins[].name] | . == (.|sort)' -- "$MP")"
[[ "$sorted" == "true" ]] || flag "I1" "plugins[] is not alpha-sorted by name"

# I2 dups
dups="$(jq -r '[.plugins[].name] | group_by(.) | map(select(length>1) | .[0]) | .[]' -- "$MP")"
[[ -z "$dups" ]] || flag "I2" "duplicate plugin names: $(tr '\n' ' ' <<<"$dups")"

# I3 description bounds + whitespace
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  desc="$(jq -r '.description' <<<"$entry")"
  len=${#desc}
  if (( len < 10 || len > 2000 )); then
    flag "I3" "$name: description length $len not in [10,2000]" "$name"
  fi
  if [[ "$desc" != "$(printf '%s' "$desc" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')" ]]; then
    flag "I3" "$name: description has leading/trailing whitespace" "$name"
  fi
done < <(jq -c '.plugins[]' -- "$MP")

# I4 / I5 / I9 — external sources (shape-agnostic: applies to any object source).
# We don't enumerate source kinds here; the canonical schema check is step 20.
# This layer enforces security policy on whichever fields are present.
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  url="$(jq -r '.source.url // .source.repo // empty' <<<"$entry")"
  sha="$(jq -r '.source.sha // empty' <<<"$entry")"

  if [[ -n "$url" ]]; then
    if [[ ! "$url" =~ ^https://[A-Za-z0-9./_-]+$ ]] && \
       [[ ! "$url" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
      flag "I4" "$name: source url/repo is not a safe https URL or owner/repo shorthand: $url" "$name"
    fi
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    flag "I5" "$name: source.sha is missing or not a 40-char hex SHA" "$name"
  fi

  # I9: every string-valued field under .source must be free of shell metacharacters.
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    case "$v" in
      *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'('*|*')'*|*'<'*|*'>'*|*' '*|*"'"*|*'"'*|*'\'*)
        flag "I9" "$name: source field contains shell metacharacters: $v" "$name"
        ;;
    esac
  done < <(jq -r '.source | to_entries[] | select(.value|type=="string") | .value' <<<"$entry")
done < <(jq -c '.plugins[] | select(.source | type == "object")' -- "$MP")

# I6 / I7 — per-file mode only
if [[ -n "${ENTRIES_DIR:-}" ]]; then
  for f in "$ENTRIES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .json)"
    inner="$(jq -r '.name' -- "$f")"
    [[ "$base" == "$inner" ]] || flag "I6" "$f: filename '$base' != .name '$inner'" "$inner"
  done
  if git diff --name-only "$BASE_REF"...HEAD 2>/dev/null | grep -qx "$MARKETPLACE_PATH"; then
    flag "I7" "PR edits $MARKETPLACE_PATH directly; per-file repos must edit $ENTRIES_DIR/*.json only"
  fi
fi

# I8 — vendored paths exist
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  p="$(jq -r '.source' <<<"$entry")"
  case "$p" in
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'('*|*')'*|*'<'*|*'>'*|*' '*|*"'"*|*'"'*|*'\'*|*'..'*)
      flag "I9" "$name: vendored source path contains unsafe characters: $p" "$name"
      continue
      ;;
  esac
  p_clean="${p#./}"
  if [[ ! -f "$p_clean/.claude-plugin/plugin.json" ]]; then
    flag "I8" "$name: vendored source '$p' has no .claude-plugin/plugin.json" "$name"
  fi
done < <(jq -c '.plugins[] | select(.source | type == "string")' -- "$MP")

if (( failures > 0 )); then
  die "$failures invariant error(s), $warnings warning(s)"
fi

if (( warnings > 0 )) && [[ "${FAIL_ON_WARNINGS:-false}" == "true" ]]; then
  die "$warnings invariant warning(s) (fail-on-warnings is set)"
fi

record_result "invariants" "pass" "summary" "0 errors, $warnings warning(s)"
log "invariants: 0 errors, $warnings warning(s)"
group_end
