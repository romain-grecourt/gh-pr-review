#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="${0##*/}"

readonly REVIEW_ROOT="${HOME}/.codex/skills/gh-pr-review/.reviews"

readonly EXIT_USAGE=2
readonly EXIT_PREREQ=3
readonly EXIT_REVIEW=4
readonly EXIT_STORAGE=5
readonly EXIT_SUBMIT=6

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME ls [--repo OWNER/REPO] [--pr NUMBER]
  $SCRIPT_NAME save --input FILE [--review-file FILE]
  $SCRIPT_NAME preview --review-file FILE
  $SCRIPT_NAME submit --review-file FILE
  $SCRIPT_NAME help

Exit codes:
  0 success
  2 usage error or missing required argument
  3 prerequisite failure
  4 invalid or unusable review file
  5 storage or review mutation failure
  6 GitHub submission failure
EOF
}

die() {
  local code="$1"
  shift
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$*" >&2
  fi
  exit "$code"
}

require_command() {
  local command_name="$1"

  command -v "$command_name" >/dev/null 2>&1 || die "$EXIT_PREREQ" "missing required command: $command_name"
}

have_hash_command() {
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1
}

sha256_file() {
  local file_path="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
  else
    sha256sum "$file_path" | awk '{print $1}'
  fi
}

COLOR_RESET=""
STYLE_HEADER=""
STYLE_META=""
STYLE_FINDING=""
STYLE_PATH=""
STYLE_HUNK=""
STYLE_ADD=""
STYLE_DEL=""
STYLE_CONTEXT=""
STYLE_HIGHLIGHT=""
STYLE_NOTE=""
STYLE_WARN=""
FINDING_DIVIDER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PREVIEW_WRAP_COLUMNS=80

init_preview_styles() {
  :
}

short_hex() {
  local value="$1"
  local width="${2:-8}"

  printf '%s\n' "${value:0:width}"
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_repo_slug() {
  local repo="$1"
  local owner
  local name

  [[ "$repo" == */* ]] || return 1
  owner="${repo%%/*}"
  name="${repo#*/}"
  [[ -n "$owner" ]] || return 1
  [[ -n "$name" ]] || return 1
  [[ "$name" != */* ]] || return 1

  printf '%s/%s\n' "$(to_lower "$owner")" "$(to_lower "$name")"
}

canonicalize_existing_dir() {
  local dir_path="$1"

  (
    cd "$dir_path" >/dev/null 2>&1 && pwd -P
  )
}

canonicalize_existing_file() {
  local file_path="$1"
  local dir_path
  local file_name

  [[ -f "$file_path" ]] || return 1

  dir_path="$(canonicalize_existing_dir "$(dirname "$file_path")")" || return 1
  file_name="$(basename "$file_path")"
  [[ -f "$dir_path/$file_name" ]] || return 1

  printf '%s/%s\n' "$dir_path" "$file_name"
}

make_temp_file_in_dir() {
  local dir_path="$1"

  mkdir -p "$dir_path" >/dev/null 2>&1 || die "$EXIT_STORAGE" "unable to create directory: $dir_path"
  mktemp "$dir_path/.tmp.${SCRIPT_NAME}.XXXXXX"
}

write_stream_atomically() {
  local destination="$1"
  local destination_dir
  local temp_file

  destination_dir="$(dirname "$destination")"
  mkdir -p "$destination_dir" >/dev/null 2>&1 || die "$EXIT_STORAGE" "unable to create directory: $destination_dir"

  temp_file="$(make_temp_file_in_dir "$destination_dir")" || die "$EXIT_STORAGE" "unable to create a temporary file in $destination_dir"
  if ! cat >"$temp_file"; then
    rm -f "$temp_file"
    die "$EXIT_STORAGE" "unable to write temporary file for $destination"
  fi

  mv "$temp_file" "$destination"
}

render_json_atomically() {
  local source_file="$1"
  local destination="$2"

  jq '
    if (.findings | type) == "array" then
      .findings |= map(
        if (.side | type) == "string" then
          .side |= ascii_downcase
        else
          .
        end
      )
    else
      .
    end
  ' "$source_file" | write_stream_atomically "$destination"
}

review_dir_for_identity() {
  local repo="$1"
  local pr_number="$2"
  local owner
  local name

  owner="${repo%%/*}"
  name="${repo#*/}"
  printf '%s/%s/%s/pr-%s\n' "$REVIEW_ROOT" "$owner" "$name" "$pr_number"
}

review_file_for_identity() {
  local repo="$1"
  local pr_number="$2"
  local review_index="$3"
  local review_dir

  review_dir="$(review_dir_for_identity "$repo" "$pr_number")"
  printf '%s/review-%03d.json\n' "$review_dir" "$review_index"
}

next_review_path_for_identity() {
  local repo="$1"
  local pr_number="$2"
  local review_dir
  local review_path
  local existing
  local base_name
  local candidate_index
  local max_index=0

  review_dir="$(review_dir_for_identity "$repo" "$pr_number")"
  mkdir -p "$review_dir" >/dev/null 2>&1 || die "$EXIT_STORAGE" "unable to create directory: $review_dir"

  shopt -s nullglob
  for existing in "$review_dir"/review-*.json; do
    base_name="${existing##*/}"
    if [[ "$base_name" =~ ^review-([0-9]+)\.json$ ]]; then
      candidate_index="${BASH_REMATCH[1]}"
      if (( 10#$candidate_index > max_index )); then
        max_index=$((10#$candidate_index))
      fi
    fi
  done
  shopt -u nullglob

  review_path="$(review_file_for_identity "$repo" "$pr_number" "$((max_index + 1))")"
  printf '%s\n' "$review_path"
}

PARSED_REVIEW_REPO=""
PARSED_REVIEW_PR_NUMBER=""
PARSED_REVIEW_INDEX=""
PARSED_REVIEW_FILE=""

parse_review_storage_path() {
  local requested_path="$1"
  local review_path
  local relative_path
  local owner
  local repo_name
  local pr_dir
  local file_name
  local pr_number
  local review_index
  local -a segments=()

  review_path="$(canonicalize_existing_file "$requested_path")" || die "$EXIT_REVIEW" "review file is missing or unreadable: $requested_path"

  case "$review_path" in
    "$REVIEW_ROOT"/*)
      relative_path="${review_path#$REVIEW_ROOT/}"
      ;;
    *)
      die "$EXIT_REVIEW" "review file is not under $REVIEW_ROOT: $review_path"
      ;;
  esac

  IFS='/' read -r -a segments <<<"$relative_path"
  [[ "${#segments[@]}" -eq 4 ]] || die "$EXIT_REVIEW" "review file path is not in the canonical storage layout: $review_path"

  owner="${segments[0]}"
  repo_name="${segments[1]}"
  pr_dir="${segments[2]}"
  file_name="${segments[3]}"

  if [[ ! "$pr_dir" =~ ^pr-([0-9]+)$ ]]; then
    die "$EXIT_REVIEW" "review file path is missing a valid PR directory: $review_path"
  fi
  pr_number="${BASH_REMATCH[1]}"
  if [[ ! "$file_name" =~ ^review-([0-9]+)\.json$ ]]; then
    die "$EXIT_REVIEW" "review file path is missing a valid review filename: $review_path"
  fi
  review_index="${BASH_REMATCH[1]}"

  PARSED_REVIEW_REPO="$(normalize_repo_slug "$owner/$repo_name")" || die "$EXIT_REVIEW" "review file path has an invalid repository slug: $review_path"
  PARSED_REVIEW_PR_NUMBER="$pr_number"
  PARSED_REVIEW_INDEX="$((10#$review_index))"
  PARSED_REVIEW_FILE="$review_path"
}

validate_review_json_file() {
  local file_path="$1"

  jq empty "$file_path" >/dev/null 2>&1 || die "$EXIT_REVIEW" "review file is malformed JSON: $file_path"

  jq -e '
    def positive_integer:
      type == "number" and floor == . and . > 0;

    def repo_slug:
      type == "string" and test("^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$");

    def sha1_hex:
      type == "string" and test("^[0-9a-f]{40}$");

    def sha256_hex:
      type == "string" and test("^[0-9a-f]{64}$");

    def repo_path:
      type == "string"
      and length > 0
      and (startswith("/") | not)
      and (contains("\n") | not)
      and (contains("\r") | not);

    type == "object"
    and (
      (keys | sort)
      == (
        ["body", "diff_fingerprint", "findings", "head_sha", "pr_number", "repo", "version"]
        + (if has("submission") then ["submission"] else [] end)
        | sort
      )
    )
    and (.version == 1)
    and (.repo | repo_slug)
    and (.pr_number | positive_integer)
    and (.head_sha | sha1_hex)
    and (.diff_fingerprint | sha256_hex)
    and (.body | type == "string")
    and (.findings | type == "array")
    and all(.findings[]?;
      type == "object"
      and ((keys | sort) == ["body", "line", "path", "side"])
      and (.path | repo_path)
      and ((.side | type) == "string")
      and ((.side | ascii_downcase) == "left" or (.side | ascii_downcase) == "right")
      and (.line | positive_integer)
      and (.body | type == "string" and length > 0)
    )
    and (
      if has("submission") then
        (.submission
          | type == "object"
          and ((keys | sort) == ["github_review_id", "submitted_at"])
          and (.submitted_at | type == "string" and length > 0)
          and (.github_review_id | positive_integer)
        )
      else
        true
      end
    )
  ' "$file_path" >/dev/null 2>&1 || die "$EXIT_REVIEW" "review file does not match review JSON v1: $file_path"
}

REVIEW_FILE=""
REVIEW_REPO=""
REVIEW_PR_NUMBER=""
REVIEW_HEAD_SHA=""
REVIEW_DIFF_FINGERPRINT=""
REVIEW_HAS_SUBMISSION=""

load_review_metadata() {
  local file_path="$1"
  local metadata

  validate_review_json_file "$file_path"
  metadata="$(jq -r '[.repo, (.pr_number | tostring), .head_sha, .diff_fingerprint, (has("submission") | tostring)] | @tsv' "$file_path")" || die "$EXIT_REVIEW" "unable to read review metadata: $file_path"

  IFS=$'\t' read -r REVIEW_REPO REVIEW_PR_NUMBER REVIEW_HEAD_SHA REVIEW_DIFF_FINGERPRINT REVIEW_HAS_SUBMISSION <<<"$metadata"
}

load_any_review_file() {
  local requested_path="$1"

  REVIEW_FILE="$(canonicalize_existing_file "$requested_path")" || die "$EXIT_REVIEW" "review file is missing or unreadable: $requested_path"
  load_review_metadata "$REVIEW_FILE"
}

load_saved_review_file() {
  local requested_path="$1"

  parse_review_storage_path "$requested_path"
  REVIEW_FILE="$PARSED_REVIEW_FILE"
  load_review_metadata "$REVIEW_FILE"

  [[ "$REVIEW_REPO" == "$PARSED_REVIEW_REPO" ]] || die "$EXIT_REVIEW" "review file path does not match the stored repo identity: $REVIEW_FILE"
  [[ "$REVIEW_PR_NUMBER" == "$PARSED_REVIEW_PR_NUMBER" ]] || die "$EXIT_REVIEW" "review file path does not match the stored PR identity: $REVIEW_FILE"
}

PREVIEW_CONTEXT_LABEL="review file only"
PREVIEW_CONTEXT_STYLE=""
PREVIEW_CONTEXT_AVAILABLE=0
PREVIEW_CONTEXT_PATCH_FILE=""
PREVIEW_CONTEXT_TEMP_DIR=""

cleanup_preview_context() {
  if [[ -n "$PREVIEW_CONTEXT_TEMP_DIR" && -d "$PREVIEW_CONTEXT_TEMP_DIR" ]]; then
    rm -rf "$PREVIEW_CONTEXT_TEMP_DIR"
  fi

  PREVIEW_CONTEXT_LABEL="review file only"
  PREVIEW_CONTEXT_STYLE="$STYLE_META"
  PREVIEW_CONTEXT_AVAILABLE=0
  PREVIEW_CONTEXT_PATCH_FILE=""
  PREVIEW_CONTEXT_TEMP_DIR=""
}

prepare_preview_context() {
  local finding_count="$1"
  local stderr_file=""
  local head_file=""
  local current_head_sha=""
  local current_fingerprint=""

  cleanup_preview_context

  if [[ "$finding_count" == "0" ]]; then
    PREVIEW_CONTEXT_LABEL="review file only"
    PREVIEW_CONTEXT_STYLE="$STYLE_META"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1 || ! have_hash_command; then
    PREVIEW_CONTEXT_LABEL="review file only"
    PREVIEW_CONTEXT_STYLE="$STYLE_META"
    return 0
  fi

  PREVIEW_CONTEXT_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-gh-pr-review.preview.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$PREVIEW_CONTEXT_TEMP_DIR" || ! -d "$PREVIEW_CONTEXT_TEMP_DIR" ]]; then
    PREVIEW_CONTEXT_LABEL="review file only"
    PREVIEW_CONTEXT_STYLE="$STYLE_META"
    return 0
  fi

  stderr_file="$PREVIEW_CONTEXT_TEMP_DIR/stderr.log"
  head_file="$PREVIEW_CONTEXT_TEMP_DIR/head.txt"
  PREVIEW_CONTEXT_PATCH_FILE="$PREVIEW_CONTEXT_TEMP_DIR/current.patch"

  if ! gh pr view "$REVIEW_PR_NUMBER" -R "$REVIEW_REPO" --json headRefOid --jq .headRefOid >"$head_file" 2>"$stderr_file"; then
    cleanup_preview_context
    return 0
  fi

  if ! gh pr diff "$REVIEW_PR_NUMBER" -R "$REVIEW_REPO" --patch --color=never >"$PREVIEW_CONTEXT_PATCH_FILE" 2>"$stderr_file"; then
    cleanup_preview_context
    return 0
  fi

  current_head_sha="$(cat "$head_file")"
  current_fingerprint="$(sha256_file "$PREVIEW_CONTEXT_PATCH_FILE" 2>/dev/null || true)"
  if [[ -z "$current_fingerprint" ]]; then
    cleanup_preview_context
    return 0
  fi

  PREVIEW_CONTEXT_AVAILABLE=1
  PREVIEW_CONTEXT_STYLE="$STYLE_META"
  if [[ "$current_head_sha" == "$REVIEW_HEAD_SHA" && "$current_fingerprint" == "$REVIEW_DIFF_FINGERPRINT" ]]; then
    PREVIEW_CONTEXT_LABEL="live hunk context"
  else
    PREVIEW_CONTEXT_LABEL="live diff mismatch"
    PREVIEW_CONTEXT_STYLE="$STYLE_WARN"
  fi
}

require_local_prerequisites() {
  require_command jq
}

require_submit_prerequisites() {
  require_local_prerequisites
  require_command gh
  have_hash_command || die "$EXIT_PREREQ" "missing required command: shasum or sha256sum"
}

run_gh_auth_status() {
  local output

  if output="$(gh auth status 2>&1)"; then
    return 0
  fi

  printf '%s\n' "$output" >&2
  exit "$EXIT_PREREQ"
}

resolve_diff_position() {
  local patch_file="$1"
  local target_path="$2"
  local target_side="$3"
  local target_line="$4"
  local position

  position="$(awk \
    -v target_path="$target_path" \
    -v target_side="$target_side" \
    -v target_line="$target_line" \
    '
      function decode_path(raw, prefix) {
        if (raw ~ /^".*"$/) {
          raw = substr(raw, 2, length(raw) - 2)
          gsub(/\\\\/, "\034", raw)
          gsub(/\\"/, "\"", raw)
          gsub(/\\t/, "\t", raw)
          gsub(/\\n/, "\n", raw)
          gsub(/\034/, "\\", raw)
        }
        if (raw != "/dev/null" && index(raw, prefix) == 1) {
          raw = substr(raw, length(prefix) + 1)
        }
        return raw
      }
      function select_current_path() {
        if (new_path == "/dev/null") {
          current_path = old_path
        } else {
          current_path = new_path
        }
      }
      BEGIN {
        found = 0
        current_path = ""
        old_path = ""
        new_path = ""
        in_hunk = 0
        position = 0
      }
      /^diff --git / {
        current_path = ""
        old_path = ""
        new_path = ""
        in_hunk = 0
        position = 0
        next
      }
      /^--- / {
        old_path = decode_path(substr($0, 5), "a/")
        next
      }
      /^\+\+\+ / {
        new_path = decode_path(substr($0, 5), "b/")
        select_current_path()
        next
      }
      /^@@ / {
        header = $0
        sub(/^@@ -/, "", header)
        sub(/ @@.*$/, "", header)
        split(header, header_parts, " ")
        left_spec = header_parts[1]
        right_spec = header_parts[2]
        sub(/^\+/, "", right_spec)
        split(left_spec, left_parts, ",")
        split(right_spec, right_parts, ",")
        left_line = left_parts[1] + 0
        right_line = right_parts[1] + 0
        in_hunk = 1
        next
      }
      {
        if (!in_hunk) {
          next
        }

        if ($0 == "\\ No newline at end of file") {
          next
        }

        prefix = substr($0, 1, 1)
        if (prefix != " " && prefix != "+" && prefix != "-") {
          next
        }

        position += 1

        if (current_path == target_path) {
          if ((prefix == " " || prefix == "-") && target_side == "left" && left_line == target_line) {
            print position
            found = 1
            exit
          }
          if ((prefix == " " || prefix == "+") && target_side == "right" && right_line == target_line) {
            print position
            found = 1
            exit
          }
        }

        if (prefix == " " || prefix == "-") {
          left_line += 1
        }
        if (prefix == " " || prefix == "+") {
          right_line += 1
        }
      }
      END {
        if (!found) {
          exit 1
        }
      }
    ' "$patch_file")" || die "$EXIT_STORAGE" "unable to resolve $target_path $target_side:$target_line against the live PR patch."

  printf '%s\n' "$position"
}

extract_finding_hunk_context() {
  local patch_file="$1"
  local target_path="$2"
  local target_side="$3"
  local target_line="$4"
  local radius="${5:-2}"
  local separator=$'\037'

  awk \
    -v target_path="$target_path" \
    -v target_side="$target_side" \
    -v target_line="$target_line" \
    -v radius="$radius" \
    -v separator="$separator" \
    '
      function decode_path(raw, prefix) {
        if (raw ~ /^".*"$/) {
          raw = substr(raw, 2, length(raw) - 2)
          gsub(/\\\\/, "\034", raw)
          gsub(/\\"/, "\"", raw)
          gsub(/\\t/, "\t", raw)
          gsub(/\\n/, "\n", raw)
          gsub(/\034/, "\\", raw)
        }
        if (raw != "/dev/null" && index(raw, prefix) == 1) {
          raw = substr(raw, length(prefix) + 1)
        }
        return raw
      }
      function select_current_path() {
        if (new_path == "/dev/null") {
          current_path = old_path
        } else {
          current_path = new_path
        }
      }
      function clear_hunk() {
        delete hunk_text
        delete hunk_display
        delete hunk_class
        hunk_count = 0
        hunk_header = ""
        target_index = 0
        in_hunk = 0
      }
      function emit_hunk(    start, stop, i, marker) {
        if (target_index == 0 || current_path != target_path) {
          return
        }
        start = target_index - radius
        if (start < 1) {
          start = 1
        }
        stop = target_index + radius
        if (stop > hunk_count) {
          stop = hunk_count
        }
        printf "HEADER%s%s%s%s%s%s%s%s\n", separator, "", separator, "", separator, "", separator, hunk_header
        for (i = start; i <= stop; i++) {
          marker = (i == target_index ? 1 : 0)
          printf "LINE%s%d%s%s%s%s%s%s\n", separator, marker, separator, hunk_class[i], separator, hunk_display[i], separator, hunk_text[i]
        }
        found = 1
      }
      BEGIN {
        found = 0
        current_path = ""
        old_path = ""
        new_path = ""
        clear_hunk()
      }
      /^diff --git / {
        if (target_index > 0) {
          emit_hunk()
          exit(found ? 0 : 1)
        }
        current_path = ""
        old_path = ""
        new_path = ""
        clear_hunk()
        next
      }
      /^--- / {
        old_path = decode_path(substr($0, 5), "a/")
        next
      }
      /^\+\+\+ / {
        new_path = decode_path(substr($0, 5), "b/")
        select_current_path()
        next
      }
      /^@@ / {
        if (target_index > 0) {
          emit_hunk()
          exit(found ? 0 : 1)
        }
        clear_hunk()
        hunk_header = $0
        header = $0
        sub(/^@@ -/, "", header)
        sub(/ @@.*$/, "", header)
        split(header, header_parts, " ")
        left_spec = header_parts[1]
        right_spec = header_parts[2]
        sub(/^\+/, "", right_spec)
        split(left_spec, left_parts, ",")
        split(right_spec, right_parts, ",")
        left_line = left_parts[1] + 0
        right_line = right_parts[1] + 0
        in_hunk = 1
        next
      }
      {
        if (!in_hunk) {
          next
        }

        if ($0 == "\\ No newline at end of file") {
          next
        }

        prefix = substr($0, 1, 1)
        if (prefix != " " && prefix != "+" && prefix != "-") {
          next
        }

        display = ""
        if (target_side == "left") {
          if (prefix == " " || prefix == "-") {
            display = left_line
          }
        } else {
          if (prefix == " " || prefix == "+") {
            display = right_line
          }
        }

        if (prefix == "+") {
          line_class = "add"
        } else if (prefix == "-") {
          line_class = "del"
        } else {
          line_class = "ctx"
        }

        hunk_count += 1
        hunk_text[hunk_count] = $0
        hunk_display[hunk_count] = display
        hunk_class[hunk_count] = line_class

        if (current_path == target_path) {
          if ((prefix == " " || prefix == "-") && target_side == "left" && left_line == target_line) {
            target_index = hunk_count
          }
          if ((prefix == " " || prefix == "+") && target_side == "right" && right_line == target_line) {
            target_index = hunk_count
          }
        }

        if (prefix == " " || prefix == "-") {
          left_line += 1
        }
        if (prefix == " " || prefix == "+") {
          right_line += 1
        }
      }
      END {
        if (target_index > 0 && !found) {
          emit_hunk()
        }
        if (!found) {
          exit 1
        }
      }
    ' "$patch_file"
}

render_finding_hunk_context() {
  local patch_file="$1"
  local target_path="$2"
  local target_side="$3"
  local target_line="$4"
  local excerpt=""
  local row=""
  local row_type=""
  local row_marker=""
  local row_class=""
  local row_display=""
  local row_text=""
  local line_style=""
  local display_number=""

  excerpt="$(extract_finding_hunk_context "$patch_file" "$target_path" "$target_side" "$target_line")" || return 1

  while IFS= read -r row || [[ -n "$row" ]]; do
    IFS=$'\037' read -r row_type row_marker row_class row_display row_text <<<"$row"
    if [[ "$row_type" == "HEADER" ]]; then
      printf '  %b%s%b\n' "$STYLE_HUNK" "$row_text" "$COLOR_RESET"
      continue
    fi

    case "$row_class" in
      add)
        line_style="$STYLE_ADD"
        ;;
      del)
        line_style="$STYLE_DEL"
        ;;
      *)
        line_style="$STYLE_CONTEXT"
        ;;
    esac

    printf -v display_number '%4s' "$row_display"
    if [[ "$row_marker" == "1" ]]; then
      printf '  %b>%b %b%s | %s%b\n' "$STYLE_HIGHLIGHT" "$COLOR_RESET" "$STYLE_HIGHLIGHT" "$display_number" "$row_text" "$COLOR_RESET"
    else
      printf '    %b%s | %s%b\n' "$line_style" "$display_number" "$row_text" "$COLOR_RESET"
    fi
  done <<<"$excerpt"
}

render_note_block() {
  local body_text="$1"
  local line=""
  local wrapped_line=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" ]]; then
      while IFS= read -r wrapped_line || [[ -n "$wrapped_line" ]]; do
        printf '  %b|%b %s\n' "$STYLE_NOTE" "$COLOR_RESET" "$wrapped_line"
      done < <(fold -s -w "$PREVIEW_WRAP_COLUMNS" <<<"$line" | sed 's/[[:space:]]*$//')
    else
      printf '  %b|%b\n' "$STYLE_NOTE" "$COLOR_RESET"
    fi
  done <<<"$body_text"
}

render_wrapped_body() {
  local body_text="$1"
  local line=""
  local wrapped_line=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" ]]; then
      while IFS= read -r wrapped_line || [[ -n "$wrapped_line" ]]; do
        printf '%s\n' "$wrapped_line"
      done < <(fold -s -w "$PREVIEW_WRAP_COLUMNS" <<<"$line" | sed 's/[[:space:]]*$//')
    else
      printf '\n'
    fi
  done <<<"$body_text"
}

build_review_payload() {
  local review_file="$1"
  local patch_file="$2"
  local payload_file="$3"
  local comments_file
  local comments_count
  local finding_json
  local path
  local side
  local line
  local position

  comments_file="$(mktemp "${TMPDIR:-/tmp}/codex-gh-pr-review.comments.XXXXXX")" || die "$EXIT_SUBMIT" "unable to create a temporary comments file."
  printf '[]\n' >"$comments_file"

  while IFS= read -r finding_json; do
    path="$(printf '%s\n' "$finding_json" | jq -r '.path')"
    side="$(printf '%s\n' "$finding_json" | jq -r '.side | ascii_downcase')"
    line="$(printf '%s\n' "$finding_json" | jq -r '.line')"
    position="$(resolve_diff_position "$patch_file" "$path" "$side" "$line")"

    jq \
      --argjson finding "$finding_json" \
      --argjson position "$position" \
      '
        . + [
          {
            path: $finding.path,
            position: $position,
            body: $finding.body
          }
        ]
      ' "$comments_file" | write_stream_atomically "$comments_file"
  done < <(jq -c '.findings[]' "$review_file")

  comments_count="$(jq 'length' "$comments_file")" || die "$EXIT_SUBMIT" "unable to read resolved comment anchors."
  [[ "$comments_count" == "$(jq '.findings | length' "$review_file")" ]] || die "$EXIT_SUBMIT" "resolved comment anchors do not match the saved findings."

  jq \
    --slurpfile comments "$comments_file" \
    --arg commit_id "$REVIEW_HEAD_SHA" \
    '
      {
        event: "COMMENT",
        commit_id: $commit_id,
        body: .body
      }
      + (if ($comments[0] | length) > 0 then
          { comments: $comments[0] }
        else
          {}
        end)
    ' "$review_file" >"$payload_file"

  rm -f "$comments_file"
}

mark_review_submitted() {
  local review_file="$1"
  local submitted_at="$2"
  local github_review_id="$3"

  jq \
    --arg submitted_at "$submitted_at" \
    --argjson github_review_id "$github_review_id" \
    '.submission = {submitted_at: $submitted_at, github_review_id: $github_review_id}' \
    "$review_file" | write_stream_atomically "$review_file"
}

command_ls() {
  local repo_filter=""
  local pr_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for --repo"
        repo_filter="$2"
        shift 2
        ;;
      --pr)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for --pr"
        pr_filter="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "$EXIT_USAGE" "unknown argument for ls: $1"
        ;;
    esac
  done

  require_local_prerequisites

  if [[ -n "$repo_filter" ]]; then
    repo_filter="$(normalize_repo_slug "$repo_filter")" || die "$EXIT_USAGE" "--repo must be in OWNER/REPO format"
  fi
  if [[ -n "$pr_filter" ]]; then
    [[ "$pr_filter" =~ ^[0-9]+$ ]] || die "$EXIT_USAGE" "--pr must be a positive integer"
    [[ "$pr_filter" != "0" ]] || die "$EXIT_USAGE" "--pr must be a positive integer"
  fi

  [[ -d "$REVIEW_ROOT" ]] || return 0

  find "$REVIEW_ROOT" -type f -name 'review-*.json' -print | while IFS= read -r review_path; do
    load_saved_review_file "$review_path"

    if [[ -n "$repo_filter" && "$REVIEW_REPO" != "$repo_filter" ]]; then
      continue
    fi
    if [[ -n "$pr_filter" && "$REVIEW_PR_NUMBER" != "$pr_filter" ]]; then
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$REVIEW_REPO" \
      "$REVIEW_PR_NUMBER" \
      "$PARSED_REVIEW_INDEX" \
      "$(if [[ "$REVIEW_HAS_SUBMISSION" == "true" ]]; then printf 'submitted'; else printf 'draft'; fi)" \
      "$REVIEW_FILE"
  done | sort -t $'\t' -k1,1 -k2,2n -k3,3n | while IFS=$'\t' read -r _ _ _ status review_file; do
    printf '%s %s\n' "$status" "$review_file"
  done
}

command_save() {
  local input_file=""
  local review_file=""
  local canonical_input_file=""
  local target_file=""
  local input_repo=""
  local input_pr_number=""
  local target_repo=""
  local target_pr_number=""
  local target_has_submission=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for --input"
        input_file="$2"
        shift 2
        ;;
      --review-file)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for --review-file"
        review_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "$EXIT_USAGE" "unknown argument for save: $1"
        ;;
    esac
  done

  [[ -n "$input_file" ]] || die "$EXIT_USAGE" "save requires --input FILE"

  require_local_prerequisites

  canonical_input_file="$(canonicalize_existing_file "$input_file")" || die "$EXIT_REVIEW" "input review JSON is missing or unreadable: $input_file"
  load_review_metadata "$canonical_input_file"

  [[ "$REVIEW_HAS_SUBMISSION" == "false" ]] || die "$EXIT_STORAGE" "save only accepts draft review documents; submission metadata is script-owned."

  input_repo="$REVIEW_REPO"
  input_pr_number="$REVIEW_PR_NUMBER"

  if [[ -n "$review_file" ]]; then
    load_saved_review_file "$review_file"
    target_file="$REVIEW_FILE"
    target_repo="$REVIEW_REPO"
    target_pr_number="$REVIEW_PR_NUMBER"
    target_has_submission="$REVIEW_HAS_SUBMISSION"

    [[ "$target_repo" == "$input_repo" ]] || die "$EXIT_STORAGE" "target review file repo does not match the input document: $target_file"
    [[ "$target_pr_number" == "$input_pr_number" ]] || die "$EXIT_STORAGE" "target review file PR does not match the input document: $target_file"
    [[ "$target_has_submission" == "false" ]] || die "$EXIT_STORAGE" "refusing to overwrite a submitted review file: $target_file"
  else
    target_file="$(next_review_path_for_identity "$input_repo" "$input_pr_number")"
  fi

  render_json_atomically "$canonical_input_file" "$target_file"
  printf '%s\n' "$target_file"
}

command_preview() {
  local review_file=""
  local finding_count=""
  local finding_index=0
  local finding_json=""
  local finding_path=""
  local finding_side=""
  local finding_line=""
  local finding_body=""
  local review_body=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --review-file)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for --review-file"
        review_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "$EXIT_USAGE" "unknown argument for preview: $1"
        ;;
    esac
  done

  [[ -n "$review_file" ]] || die "$EXIT_USAGE" "preview requires --review-file FILE"

  require_local_prerequisites
  load_any_review_file "$review_file"
  init_preview_styles

  finding_count="$(jq '.findings | length' "$REVIEW_FILE")" || die "$EXIT_REVIEW" "unable to read findings from the review file."
  prepare_preview_context "$finding_count"

  printf '%bReview Preview%b  %b%s#%s%b\n' "$STYLE_HEADER" "$COLOR_RESET" "$STYLE_PATH" "$REVIEW_REPO" "$REVIEW_PR_NUMBER" "$COLOR_RESET"
  printf '%bstate COMMENT  head %s  diff %s%b' "$STYLE_META" "$(short_hex "$REVIEW_HEAD_SHA")" "$(short_hex "$REVIEW_DIFF_FINGERPRINT")" "$COLOR_RESET"
  if [[ -n "$PREVIEW_CONTEXT_LABEL" ]]; then
    printf '  %b%s%b\n' "$PREVIEW_CONTEXT_STYLE" "$PREVIEW_CONTEXT_LABEL" "$COLOR_RESET"
  else
    printf '\n'
  fi
  printf '\n'

  printf '🔎 Inline Findings\n\n'
  if [[ "$finding_count" == "0" ]]; then
    printf '  %b(none)%b\n\n' "$STYLE_META" "$COLOR_RESET"
  else
    while IFS= read -r finding_json; do
      finding_index="$((finding_index + 1))"
      finding_path="$(printf '%s\n' "$finding_json" | jq -r '.path')"
      finding_side="$(printf '%s\n' "$finding_json" | jq -r '.side | ascii_downcase')"
      finding_line="$(printf '%s\n' "$finding_json" | jq -r '.line')"
      finding_body="$(printf '%s\n' "$finding_json" | jq -r '.body')"

      printf '◆ Finding %s  %s  %s:%s\n' "$finding_index" "$finding_path" "$finding_side" "$finding_line"
      if [[ "$PREVIEW_CONTEXT_AVAILABLE" -eq 1 ]]; then
        if ! render_finding_hunk_context "$PREVIEW_CONTEXT_PATCH_FILE" "$finding_path" "$finding_side" "$finding_line"; then
          printf '  %b[live hunk context unavailable for this finding]%b\n' "$STYLE_WARN" "$COLOR_RESET"
        fi
        printf '\n'
      fi

      render_note_block "$finding_body"
      printf '\n'
      if [[ "$finding_index" -lt "$finding_count" ]]; then
        printf '%s\n\n' "$FINDING_DIVIDER"
      fi
    done < <(jq -c '.findings[]' "$REVIEW_FILE")
  fi

  review_body="$(jq -r '.body' "$REVIEW_FILE")" || die "$EXIT_REVIEW" "unable to read the review body."
  printf '📋 Review Body\n\n'
  if [[ -n "$review_body" ]]; then
    render_wrapped_body "$review_body"
  else
    printf '%b(empty)%b\n' "$STYLE_META" "$COLOR_RESET"
  fi

  cleanup_preview_context
}

command_submit() {
  local review_file=""
  local temp_dir=""
  local current_head_sha=""
  local current_patch=""
  local current_fingerprint=""
  local payload_file=""
  local response_file=""
  local stderr_file=""
  local github_review_id=""
  local submitted_at=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --review-file)
        [[ $# -ge 2 ]] || die "$EXIT_USAGE" "missing value for --review-file"
        review_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "$EXIT_USAGE" "unknown argument for submit: $1"
        ;;
    esac
  done

  [[ -n "$review_file" ]] || die "$EXIT_USAGE" "submit requires --review-file FILE"

  require_submit_prerequisites
  load_saved_review_file "$review_file"
  [[ "$REVIEW_HAS_SUBMISSION" == "false" ]] || die "$EXIT_STORAGE" "review file is already submitted: $REVIEW_FILE"
  run_gh_auth_status

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-gh-pr-review.submit.XXXXXX")" || die "$EXIT_SUBMIT" "unable to create a temporary submit directory."
  stderr_file="$temp_dir/stderr.log"
  current_patch="$temp_dir/current.patch"
  payload_file="$temp_dir/review-payload.json"
  response_file="$temp_dir/submit-response.json"

  : >"$stderr_file"
  if ! current_head_sha="$(gh pr view "$REVIEW_PR_NUMBER" -R "$REVIEW_REPO" --json headRefOid --jq .headRefOid 2>"$stderr_file")"; then
    cat "$stderr_file" >&2
    rm -rf "$temp_dir"
    exit "$EXIT_SUBMIT"
  fi

  : >"$stderr_file"
  if ! gh pr diff "$REVIEW_PR_NUMBER" -R "$REVIEW_REPO" --patch --color=never >"$current_patch" 2>"$stderr_file"; then
    cat "$stderr_file" >&2
    rm -rf "$temp_dir"
    exit "$EXIT_SUBMIT"
  fi

  current_fingerprint="$(sha256_file "$current_patch")" || die "$EXIT_SUBMIT" "submit failed: unable to fingerprint the current PR patch."

  if [[ "$current_head_sha" != "$REVIEW_HEAD_SHA" ]]; then
    rm -rf "$temp_dir"
    die "$EXIT_REVIEW" "submit failed: the PR head changed since this review was saved."
  fi
  if [[ "$current_fingerprint" != "$REVIEW_DIFF_FINGERPRINT" ]]; then
    rm -rf "$temp_dir"
    die "$EXIT_REVIEW" "submit failed: the PR diff changed since this review was saved."
  fi

  build_review_payload "$REVIEW_FILE" "$current_patch" "$payload_file"

  : >"$stderr_file"
  if ! gh api -X POST "repos/$REVIEW_REPO/pulls/$REVIEW_PR_NUMBER/reviews" --input "$payload_file" >"$response_file" 2>"$stderr_file"; then
    cat "$stderr_file" >&2
    rm -rf "$temp_dir"
    exit "$EXIT_SUBMIT"
  fi

  github_review_id="$(jq -r '.id // empty' "$response_file")" || die "$EXIT_SUBMIT" "submit failed: unable to read GitHub review id."
  [[ "$github_review_id" =~ ^[0-9]+$ ]] || die "$EXIT_SUBMIT" "submit failed: GitHub did not return a review id."

  submitted_at="$(jq -r '.submitted_at // empty' "$response_file")" || die "$EXIT_SUBMIT" "submit failed: unable to read GitHub submission time."
  if [[ -z "$submitted_at" ]]; then
    submitted_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fi

  mark_review_submitted "$REVIEW_FILE" "$submitted_at" "$github_review_id"

  rm -rf "$temp_dir"
  printf 'submitted\n'
}

main() {
  local command="${1:-help}"

  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    ls)
      command_ls "$@"
      ;;
    save)
      command_save "$@"
      ;;
    preview)
      command_preview "$@"
      ;;
    submit)
      command_submit "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      die "$EXIT_USAGE" "unknown command: $command"
      ;;
  esac
}

main "$@"
