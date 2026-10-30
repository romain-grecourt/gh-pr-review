#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HELPER="$ROOT_DIR/scripts/gh-pr-review.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-review-tests.XXXXXX")"
FAKE_BIN="$TEST_DIR/bin"
FIXTURES="$TEST_DIR/fixtures"
TEST_HOME="$TEST_DIR/home"
OUTPUT_FILE="$TEST_DIR/stdout"
ERROR_FILE="$TEST_DIR/stderr"
GH_LOG="$TEST_DIR/gh.log"
PAYLOAD_FILE="$TEST_DIR/payload.json"

BASE_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BASE_B="1111111111111111111111111111111111111111"
HEAD_A="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
HEAD_B="2222222222222222222222222222222222222222"
REPO="owner/repo"

LAST_STATUS=0
TEST_COUNT=0

cleanup() {
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  TEST_COUNT="$((TEST_COUNT + 1))"
  printf 'ok %s - %s\n' "$TEST_COUNT" "$*"
}

run_command() {
  set +e
  "$@" >"$OUTPUT_FILE" 2>"$ERROR_FILE"
  LAST_STATUS=$?
  set -e
}

assert_status() {
  local expected="$1"

  [[ "$LAST_STATUS" -eq "$expected" ]] || {
    cat "$OUTPUT_FILE" >&2
    cat "$ERROR_FILE" >&2
    fail "expected status $expected, got $LAST_STATUS"
  }
}

assert_contains() {
  local file_path="$1"
  local expected="$2"

  grep -Fq -- "$expected" "$file_path" || {
    cat "$file_path" >&2
    fail "missing expected text: $expected"
  }
}

assert_not_contains() {
  local file_path="$1"
  local unexpected="$2"

  if grep -Fq -- "$unexpected" "$file_path"; then
    cat "$file_path" >&2
    fail "found unexpected text: $unexpected"
  fi
}

assert_jq() {
  local file_path="$1"
  local filter="$2"

  jq -e "$filter" "$file_path" >/dev/null || {
    cat "$file_path" >&2
    fail "jq assertion failed: $filter"
  }
}

file_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

review_path() {
  local pr_number="$1"
  local review_index="${2:-1}"
  local review_dir="$HOME/.codex/skills/gh-pr-review/.reviews/owner/repo/pr-$pr_number"

  mkdir -p "$review_dir"
  printf '%s/review-%03d.json\n' "$review_dir" "$review_index"
}

write_v2_review() {
  local destination="$1"
  local pr_number="$2"
  local event="$3"
  local body="$4"
  local path="${5:-}"
  local side="${6:-right}"
  local line="${7:-1}"
  local finding_body="${8:-finding}"

  jq -n \
    --arg repo "$REPO" \
    --argjson pr_number "$pr_number" \
    --arg base_sha "$BASE_A" \
    --arg head_sha "$HEAD_A" \
    --arg event "$event" \
    --arg body "$body" \
    --arg path "$path" \
    --arg side "$side" \
    --argjson line "$line" \
    --arg finding_body "$finding_body" \
    '{
      version: 2,
      repo: $repo,
      pr_number: $pr_number,
      base_sha: $base_sha,
      head_sha: $head_sha,
      event: $event,
      body: $body,
      findings: (
        if $path == "" then []
        else [{path: $path, side: $side, line: $line, body: $finding_body}]
        end
      )
    }' >"$destination"
}

write_v1_review() {
  local destination="$1"
  local pr_number="$2"
  local fingerprint="$3"
  local body="$4"
  local path="${5:-}"
  local side="${6:-right}"
  local line="${7:-1}"
  local finding_body="${8:-finding}"

  jq -n \
    --arg repo "$REPO" \
    --argjson pr_number "$pr_number" \
    --arg head_sha "$HEAD_A" \
    --arg fingerprint "$fingerprint" \
    --arg body "$body" \
    --arg path "$path" \
    --arg side "$side" \
    --argjson line "$line" \
    --arg finding_body "$finding_body" \
    '{
      version: 1,
      repo: $repo,
      pr_number: $pr_number,
      head_sha: $head_sha,
      diff_fingerprint: $fingerprint,
      body: $body,
      findings: (
        if $path == "" then []
        else [{path: $path, side: $side, line: $line, body: $finding_body}]
        end
      )
    }' >"$destination"
}

reset_fake_state() {
  : >"$GH_LOG"
  : >"$OUTPUT_FILE"
  : >"$ERROR_FILE"
  rm -f "$PAYLOAD_FILE"
  export GH_TEST_LIVE_BASE="$BASE_A"
  export GH_TEST_LIVE_HEAD="$HEAD_A"
  export GH_TEST_DIFF_MODE="normal"
  export GH_TEST_VISIBILITY="PUBLIC"
  export GH_TEST_STATE_FAIL="0"
  export GH_TEST_SUBMIT_FAIL="0"
  export GH_TEST_SUBMIT_ID="9001"
  export GH_TEST_NORMAL_CAPTURE=""
  export GH_TEST_FALLBACK_CAPTURE=""
}

mkdir -p "$FAKE_BIN" "$FIXTURES" "$TEST_HOME"
export HOME="$(cd "$TEST_HOME" && pwd -P)"
export GH_TEST_LOG="$GH_LOG"
export GH_TEST_FIXTURES="$FIXTURES"
export GH_TEST_CAPTURED_PAYLOAD="$PAYLOAD_FILE"
export GH_TEST_PATCH="$FIXTURES/current.patch"
export GH_TEST_FILES_PAGES="$FIXTURES/files.pages.json"
export GH_TEST_REVIEWS_PAGES="$FIXTURES/reviews.pages.json"
export PATH="$FAKE_BIN:$PATH"

cat >"$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'gh'
  printf ' %q' "$@"
  printf '\n'
} >>"$GH_TEST_LOG"

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  if [[ "${GH_TEST_STATE_FAIL:-0}" == "1" ]]; then
    printf '%s\n' 'state unavailable' >&2
    exit 1
  fi
  jq -n \
    --arg base "${GH_TEST_LIVE_BASE}" \
    --arg head "${GH_TEST_LIVE_HEAD}" \
    '{baseRefOid: $base, headRefOid: $head}'
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "diff" ]]; then
  if [[ "${GH_TEST_DIFF_MODE:-normal}" == "too-large" ]]; then
    printf '%s\n' 'GraphQL: diff too_large' >&2
    exit 1
  fi
  if [[ -n "${GH_TEST_NORMAL_CAPTURE:-}" ]]; then
    tee "$GH_TEST_NORMAL_CAPTURE" <"$GH_TEST_PATCH"
  else
    cat "$GH_TEST_PATCH"
  fi
  exit 0
fi

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  printf '%s\n' "${GH_TEST_VISIBILITY:-PUBLIC}"
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  endpoint=""
  input_file=""
  method="GET"
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == "--input" ]]; then
      input_file="$argument"
    elif [[ "$previous" == "-X" ]]; then
      method="$argument"
    elif [[ "$argument" == "user" || "$argument" == repos/* ]]; then
      endpoint="$argument"
    fi
    previous="$argument"
  done

  if [[ "$endpoint" == "user" ]]; then
    printf '%s\n' 'reviewer'
    exit 0
  fi

  if [[ "$method" == "POST" && "$endpoint" == */reviews ]]; then
    cp "$input_file" "$GH_TEST_CAPTURED_PAYLOAD"
    if [[ "${GH_TEST_SUBMIT_FAIL:-0}" == "1" ]]; then
      printf '%s\n' 'submission failed' >&2
      exit 1
    fi
    jq -n \
      --argjson id "${GH_TEST_SUBMIT_ID:-9001}" \
      '{id: $id, submitted_at: "2026-10-30T12:00:00Z"}'
    exit 0
  fi

  if [[ "$endpoint" == */files\?per_page=100 ]]; then
    cat "$GH_TEST_FILES_PAGES"
    exit 0
  fi

  if [[ "$endpoint" == */reviews\?per_page=100 ]]; then
    cat "$GH_TEST_REVIEWS_PAGES"
    exit 0
  fi

  if [[ "$endpoint" =~ /reviews/([0-9]+)/comments\?per_page=100$ ]]; then
    cat "$GH_TEST_FIXTURES/comments-${BASH_REMATCH[1]}.pages.json"
    exit 0
  fi

  printf 'unsupported fake gh api endpoint: %s\n' "$endpoint" >&2
  exit 1
fi

printf 'unsupported fake gh call: %s\n' "$*" >&2
exit 1
FAKE_GH

cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'curl'
  printf ' %q' "$@"
  printf '\n'
} >>"$GH_TEST_LOG"

if [[ -n "${GH_TEST_FALLBACK_CAPTURE:-}" ]]; then
  tee "$GH_TEST_FALLBACK_CAPTURE" <"$GH_TEST_PATCH"
else
  cat "$GH_TEST_PATCH"
fi
FAKE_CURL

chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/curl"

cat >"$GH_TEST_PATCH" <<'PATCH'
diff --git a/src/Legacy.java b/src/Legacy.java
index 1111111..2222222 100644
--- a/src/Legacy.java
+++ b/src/Legacy.java
@@ -4,3 +4,3 @@
 context4
-old5
+new5
 context6
PATCH

PATCH_HASH="$(file_hash "$GH_TEST_PATCH")"
printf '[[]]\n' >"$GH_TEST_FILES_PAGES"
printf '[[]]\n' >"$GH_TEST_REVIEWS_PAGES"

bash -n "$HELPER"
pass "helper has valid Bash syntax"

reset_fake_state
V2_INPUT="$TEST_DIR/v2-input.json"
write_v2_review "$V2_INPUT" 100 COMMENT "v2 draft" \
  "src/Target.java" RIGHT 10 "target finding"
run_command "$HELPER" save --input "$V2_INPUT"
assert_status 0
V2_SAVED="$(cat "$OUTPUT_FILE")"
assert_jq "$V2_SAVED" \
  '.version == 2 and .findings[0].side == "right" and has("submission") == false'

V1_INPUT="$TEST_DIR/v1-input.json"
write_v1_review "$V1_INPUT" 101 "$PATCH_HASH" "v1 draft" \
  "src/Legacy.java" LEFT 5 "legacy finding"
run_command "$HELPER" save --input "$V1_INPUT"
assert_status 0
V1_SAVED="$(cat "$OUTPUT_FILE")"
assert_jq "$V1_SAVED" \
  '.version == 1 and .findings[0].side == "left" and has("event") == false'

run_command "$HELPER" ls --repo "$REPO"
assert_status 0
assert_contains "$OUTPUT_FILE" "$V2_SAVED"
assert_contains "$OUTPUT_FILE" "$V1_SAVED"
pass "save and list support v2 and legacy v1 reviews"

reset_fake_state
jq -n '[[
  {
    filename: "src/Legacy.java",
    patch: "@@ -4,3 +4,3 @@\n context4\n-old5\n+new5\n context6"
  }
]]' >"$GH_TEST_FILES_PAGES"
V1_BEFORE="$TEST_DIR/v1-before.json"
cp "$V1_SAVED" "$V1_BEFORE"
run_command "$HELPER" preview --review-file "$V1_SAVED"
assert_status 0
assert_contains "$OUTPUT_FILE" "live validation"
assert_contains "$OUTPUT_FILE" "new5"
cmp -s "$V1_BEFORE" "$V1_SAVED" ||
  fail "v1 preview rewrote the saved review"

V1_EDIT="$TEST_DIR/v1-edit.json"
jq '.body = "edited v1 body"' "$V1_SAVED" >"$V1_EDIT"
run_command "$HELPER" save --input "$V1_EDIT" --review-file "$V1_SAVED"
assert_status 0
assert_jq "$V1_SAVED" '.version == 1 and .body == "edited v1 body"'
pass "v1 preview is byte-preserving and v1 editing remains supported"

reset_fake_state
jq -n '
  def filler($start; $count):
    [
      range($start; $start + $count)
      | {
          filename: ("src/Filler" + (tostring) + ".java"),
          patch: "@@ -1 +1 @@\n-old\n+new"
        }
    ];
  [
    filler(0; 100),
    filler(100; 100),
    filler(200; 100),
    (
      filler(300; 40)
      + [
          {
            filename: "src/Target.java",
            patch: "@@ -8,4 +8,4 @@\n context8\n-old9\n+new9\n target10\n context11"
          }
        ]
    )
  ]
' >"$GH_TEST_FILES_PAGES"
assert_jq "$GH_TEST_FILES_PAGES" '[.[][]] | length == 341'

LARGE_REVIEW="$(review_path 341)"
write_v2_review "$LARGE_REVIEW" 341 COMMENT "large PR" \
  "src/Target.java" right 10 "large finding"
run_command "$HELPER" preview --review-file "$LARGE_REVIEW"
assert_status 0
assert_contains "$OUTPUT_FILE" "live validation"
assert_contains "$OUTPUT_FILE" "target10"
assert_contains "$GH_LOG" "--paginate"
assert_contains "$GH_LOG" "files\?per_page=100"
assert_not_contains "$GH_LOG" "pr diff"

run_command "$HELPER" submit --review-file "$LARGE_REVIEW"
assert_status 0
assert_not_contains "$GH_LOG" "pr diff"
assert_jq "$PAYLOAD_FILE" \
  '.comments[0].line == 10 and .comments[0].side == "RIGHT" and (.comments[0] | has("position") | not)'
assert_not_contains "$PAYLOAD_FILE" '"position"'
assert_jq "$LARGE_REVIEW" \
  '.submission.github_review_id == 9001 and .version == 2'
pass "341-file v2 reviews paginate context and submit native anchors without a diff"

reset_fake_state
STALE_BASE="$(review_path 342)"
write_v2_review "$STALE_BASE" 342 COMMENT "stale base"
STALE_BASE_HASH="$(file_hash "$STALE_BASE")"
export GH_TEST_LIVE_BASE="$BASE_B"
run_command "$HELPER" submit --review-file "$STALE_BASE"
assert_status 4
assert_contains "$ERROR_FILE" "PR base changed"
[[ "$(file_hash "$STALE_BASE")" == "$STALE_BASE_HASH" ]] ||
  fail "stale-base submission changed the draft"
assert_not_contains "$GH_LOG" "-X POST"

reset_fake_state
STALE_HEAD="$(review_path 343)"
write_v2_review "$STALE_HEAD" 343 COMMENT "stale head"
STALE_HEAD_HASH="$(file_hash "$STALE_HEAD")"
export GH_TEST_LIVE_HEAD="$HEAD_B"
run_command "$HELPER" submit --review-file "$STALE_HEAD"
assert_status 4
assert_contains "$ERROR_FILE" "PR head changed"
[[ "$(file_hash "$STALE_HEAD")" == "$STALE_HEAD_HASH" ]] ||
  fail "stale-head submission changed the draft"
assert_not_contains "$GH_LOG" "-X POST"
pass "v2 submission rejects stale base and head SHAs without mutation"

reset_fake_state
MISSING_PATCH="$(review_path 344)"
write_v2_review "$MISSING_PATCH" 344 COMMENT "missing patch" \
  "src/Missing.java" right 7 "missing context"
jq -n '[[{filename: "src/Missing.java"}]]' >"$GH_TEST_FILES_PAGES"
run_command "$HELPER" preview --review-file "$MISSING_PATCH"
assert_status 0
assert_contains "$OUTPUT_FILE" "partial validation"
assert_contains "$OUTPUT_FILE" "missing patch"

reset_fake_state
export GH_TEST_STATE_FAIL="1"
run_command "$HELPER" preview --review-file "$MISSING_PATCH"
assert_status 0
assert_contains "$OUTPUT_FILE" "offline validation"
pass "preview labels missing patches, partial validation, and offline validation"

reset_fake_state
REPEATED_PATH="$(review_path 345)"
write_v2_review "$REPEATED_PATH" 345 REQUEST_CHANGES "repeated path" \
  "src/Repeated.java" right 12 "first occurrence"
jq '.findings += [{
  path: "src/Repeated.java",
  side: "left",
  line: 8,
  body: "second occurrence"
}]' "$REPEATED_PATH" >"$TEST_DIR/repeated.tmp"
mv "$TEST_DIR/repeated.tmp" "$REPEATED_PATH"
cat >"$GH_TEST_PATCH" <<'REPEATED_PATCH'
diff --git a/src/Repeated.java b/src/Repeated.java
@@ -1 +1 @@
-first
+first changed
diff --git a/src/Repeated.java b/src/Repeated.java
@@ -8 +12 @@
-second
+second changed
REPEATED_PATCH
run_command "$HELPER" submit --review-file "$REPEATED_PATH"
assert_status 0
assert_not_contains "$GH_LOG" "pr diff"
assert_jq "$PAYLOAD_FILE" \
  '.event == "REQUEST_CHANGES" and (.comments | length) == 2 and .comments[0].line == 12 and .comments[1].line == 8'
assert_not_contains "$PAYLOAD_FILE" '"position"'
pass "repeated paths across commits use saved native line anchors"

cat >"$GH_TEST_PATCH" <<'PATCH'
diff --git a/src/Legacy.java b/src/Legacy.java
index 1111111..2222222 100644
--- a/src/Legacy.java
+++ b/src/Legacy.java
@@ -4,3 +4,3 @@
 context4
-old5
+new5
 context6
PATCH
PATCH_HASH="$(file_hash "$GH_TEST_PATCH")"

reset_fake_state
NORMAL_CAPTURE="$TEST_DIR/normal.patch"
export GH_TEST_NORMAL_CAPTURE="$NORMAL_CAPTURE"
V1_NORMAL="$(review_path 346)"
write_v1_review "$V1_NORMAL" 346 "$PATCH_HASH" "normal v1"
jq '.event = "APPROVE"' "$V1_NORMAL" >"$TEST_DIR/v1-event.tmp"
mv "$TEST_DIR/v1-event.tmp" "$V1_NORMAL"
run_command "$HELPER" submit --review-file "$V1_NORMAL"
assert_status 0
assert_jq "$PAYLOAD_FILE" '.event == "APPROVE"'

reset_fake_state
FALLBACK_CAPTURE="$TEST_DIR/fallback.patch"
export GH_TEST_DIFF_MODE="too-large"
export GH_TEST_VISIBILITY="PUBLIC"
export GH_TEST_FALLBACK_CAPTURE="$FALLBACK_CAPTURE"
V1_PUBLIC="$(review_path 347)"
write_v1_review "$V1_PUBLIC" 347 "$PATCH_HASH" "public large v1"
run_command "$HELPER" submit --review-file "$V1_PUBLIC"
assert_status 0
assert_contains "$GH_LOG" ".patch"
cmp -s "$NORMAL_CAPTURE" "$FALLBACK_CAPTURE" ||
  fail "public .patch fallback differs from normal gh pr diff bytes"

reset_fake_state
export GH_TEST_DIFF_MODE="too-large"
export GH_TEST_VISIBILITY="PRIVATE"
V1_PRIVATE="$(review_path 348)"
write_v1_review "$V1_PRIVATE" 348 "$PATCH_HASH" "private large v1"
V1_PRIVATE_HASH="$(file_hash "$V1_PRIVATE")"
run_command "$HELPER" submit --review-file "$V1_PRIVATE"
assert_status 4
assert_contains "$ERROR_FILE" \
  "review JSON v1 cannot validate a large private PR"
[[ "$(file_hash "$V1_PRIVATE")" == "$V1_PRIVATE_HASH" ]] ||
  fail "private large v1 failure changed the draft"
assert_not_contains "$GH_LOG" "-X POST"
pass "v1 uses a byte-identical public .patch fallback and guides private large PRs to v2"

reset_fake_state
FAILED_SUBMIT="$(review_path 349)"
write_v2_review "$FAILED_SUBMIT" 349 APPROVE "failed submission"
FAILED_SUBMIT_HASH="$(file_hash "$FAILED_SUBMIT")"
export GH_TEST_SUBMIT_FAIL="1"
run_command "$HELPER" submit --review-file "$FAILED_SUBMIT"
assert_status 6
assert_contains "$ERROR_FILE" "submission failed"
[[ "$(file_hash "$FAILED_SUBMIT")" == "$FAILED_SUBMIT_HASH" ]] ||
  fail "failed GitHub submission changed the draft"
pass "failed submissions leave drafts byte-for-byte untouched"

reset_fake_state
LEGACY_RECONCILE="$(review_path 350)"
write_v1_review "$LEGACY_RECONCILE" 350 "$PATCH_HASH" \
  "Legacy body continues" "src/Legacy.java" right 5 \
  "Legacy finding continues"
jq -n \
  --arg head "$HEAD_A" \
  '[[{
    id: 150,
    user: {login: "reviewer"},
    commit_id: $head,
    state: "COMMENTED",
    body: "Legacy body\r\n  continues",
    submitted_at: "2026-10-30T13:00:00Z"
  }]]' >"$GH_TEST_REVIEWS_PAGES"
jq -n '[[{
  path: "src/Legacy.java",
  body: "Legacy finding\r\ncontinues"
}]]' >"$FIXTURES/comments-150.pages.json"
run_command "$HELPER" reconcile --review-file "$LEGACY_RECONCILE"
assert_status 0
assert_jq "$LEGACY_RECONCILE" \
  '.version == 1 and has("event") == false and .submission.github_review_id == 150'
pass "legacy no-event v1 reviews reconcile as COMMENTED"

reset_fake_state
UNIQUE_RECONCILE="$(review_path 351)"
write_v2_review "$UNIQUE_RECONCILE" 351 APPROVE \
  "Approved body continues" \
  "src/Approve.java" right 3 "Approved finding continues"
jq -n \
  --arg head "$HEAD_A" \
  '[[
    {
      id: 250,
      user: {login: "someone-else"},
      commit_id: $head,
      state: "APPROVED",
      body: "Approved body continues",
      submitted_at: "2026-10-30T14:00:00Z"
    },
    {
      id: 251,
      user: {login: "reviewer"},
      commit_id: $head,
      state: "APPROVED",
      body: "Approved body\r\n  continues",
      submitted_at: "2026-10-30T14:01:00Z"
    }
  ]]' >"$GH_TEST_REVIEWS_PAGES"
jq -n '[[{
  path: "src/Approve.java",
  body: "Approved finding\r\ncontinues"
}]]' >"$FIXTURES/comments-251.pages.json"
run_command "$HELPER" reconcile --review-file "$UNIQUE_RECONCILE"
assert_status 0
assert_jq "$UNIQUE_RECONCILE" \
  '.submission.github_review_id == 251 and .submission.submitted_at == "2026-10-30T14:01:00Z"'
pass "reconciliation verifies user, head, event, normalized body, and findings"

reset_fake_state
AMBIGUOUS_RECONCILE="$(review_path 352)"
write_v2_review "$AMBIGUOUS_RECONCILE" 352 COMMENT "ambiguous" \
  "src/Ambiguous.java" right 4 "same finding"
jq -n \
  --arg head "$HEAD_A" \
  '[[
    {
      id: 301,
      user: {login: "reviewer"},
      commit_id: $head,
      state: "COMMENTED",
      body: "ambiguous",
      submitted_at: "2026-10-30T15:00:00Z"
    },
    {
      id: 302,
      user: {login: "reviewer"},
      commit_id: $head,
      state: "COMMENTED",
      body: "ambiguous",
      submitted_at: "2026-10-30T15:01:00Z"
    }
  ]]' >"$GH_TEST_REVIEWS_PAGES"
for id in 301 302; do
  jq -n '[[{
    path: "src/Ambiguous.java",
    body: "same finding"
  }]]' >"$FIXTURES/comments-$id.pages.json"
done
AMBIGUOUS_HASH="$(file_hash "$AMBIGUOUS_RECONCILE")"
run_command "$HELPER" reconcile --review-file "$AMBIGUOUS_RECONCILE"
assert_status 4
assert_contains "$ERROR_FILE" "multiple GitHub reviews match"
[[ "$(file_hash "$AMBIGUOUS_RECONCILE")" == "$AMBIGUOUS_HASH" ]] ||
  fail "ambiguous reconciliation changed the draft"

run_command "$HELPER" reconcile --review-file "$AMBIGUOUS_RECONCILE" \
  --github-review-id 302
assert_status 0
assert_jq "$AMBIGUOUS_RECONCILE" \
  '.submission.github_review_id == 302'
pass "ambiguous reconciliation is non-mutating and supports an exact review id"

printf '1..%s\n' "$TEST_COUNT"
