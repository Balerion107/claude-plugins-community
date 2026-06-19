#!/usr/bin/env bash
# Synthesis-path test for bump.sh: a strict:false (skills-only) external with no
# plugin.json must be SYNTHESIZED + validated + bumped (not hard-skipped), exactly
# as validate-plugins/30-validate-cli-external.sh does — while a default-strict
# entry with no manifest stays fail-closed ("no plugin manifest"), and a
# default-strict entry WITH a manifest bumps unchanged (byte-identical default).
#
# Unlike test-bump.sh (which is network/gh/claude-free because every fixture
# short-circuits before `git ls-remote`), this test must drive bump.sh THROUGH the
# clone → resolve_external_manifest → validate → per-entry commit+PR path. It does
# so hermetically with PATH-shim `git`/`claude`/`gh`/`timeout` executables whose
# DEFAULT case fails closed (exit 1, never the real binary) — so a missing case is
# a loud test failure, never a live API call. It sources the REAL
# validate-plugins/lib/common.sh so the actual resolve_external_manifest is exercised.
#
# Runs in pr-mode: per-entry — the mode claude-plugins-community's nightly uses.
# Runs identically on macOS bash 3.2 and Linux bash 5.x (no bash-4 features, shims
# are scripts not exported functions, heredoc fixtures).

set -euo pipefail
cd "$(dirname "$0")"
ACTION_PATH="$PWD"
COMMON_SH="$ACTION_PATH/../validate-plugins/lib/common.sh"
[[ -f "$COMMON_SH" ]] || { echo "FATAL: real common.sh not found at $COMMON_SH" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

# Stub HEAD the git shim reports for every ls-remote (40 hex, distinct from every
# fixture's old sha so new != old → each entry is "stale").
HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# ---- PATH shims (executable scripts, fail-closed default) -------------------
mkdir -p "$TMP/bin"

cat > "$TMP/bin/git" <<EOF
#!/usr/bin/env bash
# Hermetic git shim. ls-remote → fixed HEAD; clone → mkdir dest (plugin.json only
# for the *charlie* fixture); fetch/checkout/init/remote/ls-tree (incl. via -C) →
# no-op 0. Anything else fails closed.
case "\$1" in
  ls-remote) printf '%s\tHEAD\n' "$HEAD_SHA"; exit 0 ;;
  clone)
    # git clone --quiet --depth 1 -- <url> <dest> : dest is the last arg, url the one before.
    a1=""; a2=""
    for a in "\$@"; do a1="\$a2"; a2="\$a"; done
    url="\$a1"; dest="\$a2"
    mkdir -p "\$dest" || exit 1
    case "\$url" in
      *charlie*) mkdir -p "\$dest/.claude-plugin" && printf '{"name":"charlie"}' > "\$dest/.claude-plugin/plugin.json" || exit 1 ;;
    esac
    exit 0 ;;
  # -C is a deliberate catch-all no-op for the in-clone ops bump.sh runs via
  # \`git -C "\$dest" fetch|checkout\` (and the subtree-probe's init/remote/fetch/
  # ls-tree, unreached here — no fixture sets source.path). We do not dispatch on
  # the inner verb (\$3): every in-clone op the current fixtures trigger is an
  # intended no-op, and the clone arm already laid down the tree.
  -C|init|remote|fetch|checkout|ls-tree) exit 0 ;;
  *) echo "git shim: unexpected invocation: \$*" >&2; exit 1 ;;
esac
EOF

cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
# Hermetic claude shim: `plugin validate <manifest>` always passes; nothing else.
if [[ "$1" == "plugin" && "$2" == "validate" ]]; then exit 0; fi
echo "claude shim: unexpected invocation: $*" >&2; exit 1
EOF

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Hermetic gh shim covering the per-entry commit+PR phase. Fails closed otherwise.
case "$1" in
  pr)
    case "$2" in
      list)
        # Non-empty URL ONLY for the branch named in OPEN_PR_BRANCH — exercises the
        # per-entry open-PR early-skip (bump.sh skips clone+validate when a slug
        # already has an open bump PR). Empty otherwise → the create path.
        _head=""; _prev=""
        for _a in "$@"; do [ "$_prev" = "--head" ] && _head="$_a"; _prev="$_a"; done
        if [ -n "${OPEN_PR_BRANCH:-}" ] && [ "$_head" = "$OPEN_PR_BRANCH" ]; then
          echo "https://github.com/acme/repo/pull/99"
        else echo ""; fi ;;
      create) echo "https://github.com/acme/repo/pull/1" ;;
      edit)   : ;;
      *) echo "gh shim: unexpected pr subcommand: $*" >&2; exit 1 ;;
    esac
    exit 0 ;;
  api)
    case "$2" in
      graphql) cat >/dev/null 2>&1 || true; echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; exit 0 ;;  # createCommitOnBranch oid
      -X)      exit 0 ;;                                        # POST/PATCH .../git/refs
      *)       echo "cccccccccccccccccccccccccccccccccccccccc"; exit 0 ;;  # repos/.../git/ref/heads/<base> .object.sha
    esac ;;
  *) echo "gh shim: unexpected invocation: $*" >&2; exit 1 ;;
esac
EOF

cat > "$TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
# Hermetic timeout shim: strip an optional `-k <n>` and the duration, exec the rest.
[[ "$1" == "-k" ]] && shift 2
shift
exec "$@"
EOF

chmod +x "$TMP/bin/git" "$TMP/bin/claude" "$TMP/bin/gh" "$TMP/bin/timeout"

# ---- run bump.sh against a fixture ------------------------------------------
mk() { local f="$TMP/$1.json"; cat > "$f"; printf '%s' "$f"; }

work=""
run_bump() {
  work="$TMP/work.json"; cp "$1" "$work"
  : > "$TMP/out.txt"; : > "$TMP/sum.md"
  set +e
  OUT="$(
    PATH="$TMP/bin:$PATH" \
    VALIDATE_LIB="$COMMON_SH" VALIDATE_TMP="$TMP" \
    MARKETPLACE_PATH="$work" MAX_BUMPS=20 \
    ALLOWED_HOSTS="github.com gitlab.com bitbucket.org" \
    PR_MODE="per-entry" PR_BRANCH="bump/plugin-shas" BASE_BRANCH="main" \
    GH_TOKEN="dummy" GITHUB_REPOSITORY="acme/repo" \
    ONLY="${ONLY_FIXTURE:-}" OPEN_PR_BRANCH="${OPEN_PR_BRANCH:-}" \
    RUN_URL="https://github.com/acme/repo/actions/runs/1" \
    GITHUB_OUTPUT="$TMP/out.txt" GITHUB_STEP_SUMMARY="$TMP/sum.md" \
    bash "$ACTION_PATH/scripts/bump.sh" 2>&1
  )"
  RC=$?
  set -e
  BUMPED_JSON="$(sed -n 's/^bumped=//p' "$TMP/out.txt")";   [[ -n "$BUMPED_JSON" ]]  || BUMPED_JSON='[]'
  SKIPPED_JSON="$(sed -n 's/^skipped=//p' "$TMP/out.txt")"; [[ -n "$SKIPPED_JSON" ]] || SKIPPED_JSON='[]'
  # pr-urls is the per-entry commit+PR phase's output (one {name,branch,pr_url} per
  # opened PR). Parsing it lets the test assert the PR phase actually RAN, not just
  # that an entry reached bumped[] (which is populated before that phase).
  PRURLS_JSON="$(sed -n 's/^pr-urls=//p' "$TMP/out.txt" | tail -1)"; [[ -n "$PRURLS_JSON" ]] || PRURLS_JSON='[]'
}

assert_bumped() {  # NAME LABEL
  total=$((total+1))
  if [[ "$(jq -r --arg n "$1" '[.[]|select(.name==$n)]|length' <<<"$BUMPED_JSON")" == "1" ]]; then echo "  PASS $2"
  else echo "  FAIL $2 — '$1' not in bumped[] (bumped=$BUMPED_JSON)"; failures=$((failures+1)); fi
}
assert_skip_reason() {  # NAME SUBSTR LABEL
  total=$((total+1))
  local got; got="$(jq -r --arg n "$1" '.[]|select(.name==$n)|.reason' <<<"$SKIPPED_JSON")"
  if [[ "$got" == *"$2"* ]]; then echo "  PASS $3"
  else echo "  FAIL $3 — '$1' reason='$got' expected to contain '$2'"; failures=$((failures+1)); fi
}
assert_not_bumped() {  # NAME LABEL
  total=$((total+1))
  if [[ "$(jq -r --arg n "$1" '[.[]|select(.name==$n)]|length' <<<"$BUMPED_JSON")" == "0" ]]; then echo "  PASS $2"
  else echo "  FAIL $2 — '$1' unexpectedly in bumped[]"; failures=$((failures+1)); fi
}
assert_out() {  # SUBSTR LABEL
  total=$((total+1))
  if grep -qF "$1" <<<"$OUT"; then echo "  PASS $2"
  else echo "  FAIL $2 — output missing '$1'"; failures=$((failures+1)); fi
}
assert_rc() {  # EXPECTED LABEL
  total=$((total+1))
  if [[ "$RC" == "$1" ]]; then echo "  PASS $2"
  else echo "  FAIL $2 — exit $RC, expected $1"; failures=$((failures+1)); fi
}
assert_pr_opened() {  # NAME BRANCH LABEL — entry NAME has a pr-urls record on BRANCH with a non-empty pr_url
  total=$((total+1))
  local br url; br="$(jq -r --arg n "$1" '.[]|select(.name==$n)|.branch' <<<"$PRURLS_JSON")"
  url="$(jq -r --arg n "$1" '.[]|select(.name==$n)|.pr_url' <<<"$PRURLS_JSON")"
  if [[ "$br" == "$2" && -n "$url" && "$url" != "null" ]]; then echo "  PASS $3"
  else echo "  FAIL $3 — '$1' pr-urls branch='$br' url='$url' (expected branch '$2', non-empty url)"; failures=$((failures+1)); fi
}
assert_not_skipped() {  # NAME LABEL
  total=$((total+1))
  if [[ "$(jq -r --arg n "$1" '[.[]|select(.name==$n)]|length' <<<"$SKIPPED_JSON")" == "0" ]]; then echo "  PASS $2"
  else echo "  FAIL $2 — '$1' unexpectedly in skipped[]"; failures=$((failures+1)); fi
}

echo "=== bump-plugin-shas manifest-synthesis tests (per-entry) ==="

# A 3-entry fixture, all on github.com, no subdir (so the no-op subtree probe is
# skipped), each sha != the stub HEAD (so each is "stale"):
#   alpha   — strict:false, no plugin.json  → SYNTHESIZED + bumped
#   beta    — default strict, no plugin.json → SKIPPED "no plugin manifest" (fail-closed)
#   charlie — default strict, HAS plugin.json (clone shim) → bumped unchanged (regression guard)
# FIXTURE↔SHIM CONTRACT: the git clone shim writes a plugin.json ONLY for a *charlie*
# url, so alpha/beta deliberately get an EMPTY clone tree — that is what forces the
# synthesize (alpha, strict:false → mrc=2) vs fail-closed (beta, strict-default → mrc=1)
# paths. Renaming a fixture must preserve this: a name matching the shim's `*charlie*`
# glob would get a real manifest and silently turn the synth assertion hollow.
f=$(mk synth <<'EOF'
{"plugins":[
  {"name":"alpha","strict":false,"source":{"url":"https://github.com/acme/alpha","sha":"1111111111111111111111111111111111111111"}},
  {"name":"beta","source":{"url":"https://github.com/acme/beta","sha":"2222222222222222222222222222222222222222"}},
  {"name":"charlie","source":{"url":"https://github.com/acme/charlie","sha":"3333333333333333333333333333333333333333"}}
]}
EOF
)
run_bump "$f"
assert_rc          0                                         "run exits 0"
assert_bumped      "alpha"                                   "strict:false + no manifest → synthesized + bumped"
assert_out         "synthesized a minimal one"               "synthesis is logged (mrc==2 parity with validate-plugins)"
assert_skip_reason "beta" "no plugin manifest"               "default-strict + no manifest → fail-closed skip"
assert_not_bumped  "beta"                                    "default-strict + no manifest → NOT bumped"
assert_bumped      "charlie"                                 "default-strict + real manifest → bumped unchanged (byte-identical default)"
# The per-entry commit+PR phase runs AFTER bumped[] is populated, so assert it
# actually executed (PR opened, pr-urls recorded) — otherwise the gh-shim'd
# commit/PR path is unverified and a regression there would pass silently.
assert_out         "Opened PR"                               "per-entry commit+PR phase ran (PR opened)"
assert_pr_opened   "alpha" "bump/alpha"                      "synthesized entry produced a per-entry PR on bump/alpha"

echo
echo "--- ONLY + synthesis intersection ---"
# only=alpha over the same 3-entry fixture: the strict:false target must STILL
# synthesize + bump (the only-guard at bump.sh sits BEFORE strict-resolution), and
# the non-targets are plain-continued (neither bumped nor recorded in skipped[]).
ONLY_FIXTURE="alpha"
run_bump "$f"
ONLY_FIXTURE=""
assert_rc          0                                         "only=alpha run exits 0"
assert_bumped      "alpha"                                   "only=alpha + strict:false → still synthesized + bumped"
assert_not_bumped  "charlie"                                 "only=alpha → charlie (non-target) not bumped"
assert_not_bumped  "beta"                                    "only=alpha → beta (non-target) not bumped"
assert_not_skipped "beta"                                    "only=alpha → beta plain-continued (not in skipped[])"
assert_not_skipped "charlie"                                 "only=alpha → charlie plain-continued (not in skipped[])"

echo
echo "--- per-entry open-PR early-skip ---"
# A slug with an open bump PR is skipped before clone+validate (budget-saving,
# live -community nightly behavior). With an open PR on bump/alpha: alpha early-
# skips with that reason; charlie still bumps (its branch has no open PR).
OPEN_PR_BRANCH="bump/alpha"
run_bump "$f"
OPEN_PR_BRANCH=""
assert_skip_reason "alpha" "open bump PR already exists"     "open PR on bump/alpha → alpha early-skipped with that reason"
assert_not_bumped  "alpha"                                   "open-PR alpha not bumped"
assert_bumped      "charlie"                                 "open PR on alpha does not block charlie's bump"

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
