# GitHub Submission Workflow

Use this reference only for the `submit-to-github` mode selected in
`SKILL.md`. Use the review-text rules and default event from `SKILL.md`;
this file only covers GitHub-specific mechanics for validating the
approved draft, finalizing one canonical review, and submitting it.

## Preconditions

- This workflow supports pull requests hosted on `github.com` only. If
  the user supplies a PR URL on another host, stop and tell them this
  skill does not support that host.
- Pure local artifact processing is allowed in this submission workflow
  even under `static-review`, but only for review draft JSON, review
  payload JSON, the PR-scoped runtime ownership record JSON under
  `${TMPDIR:-/tmp}/codex-gh-pr-review-runtime/`, normalized diff text,
  and fetched GitHub metadata or discussion artifacts used by this
  workflow.
- For that runtime ownership record, tooling may parse or serialize only
  cleanup metadata such as the marker, PID, command, cwd, and temp
  paths created for prohibited runtime validation.
- Do not apply that exception to repository source files, copied code
  snippets, generated outputs, or ad hoc repro material.
- Under this exception, tooling may parse, transform, hash, relocate,
  or serialize review artifacts, but must not import, evaluate,
  compile, test, or run repository code.
- Verify a real GitHub write path exists before attempting any write.
- Ask for explicit confirmation before creating a review.
- Load the per-PR draft artifact from
  `${TMPDIR:-/tmp}/codex-gh-pr-review/<pr-repo-safe>__pr-<number>.json`.
  If it is missing, unreadable, malformed, contaminated, or quarantined,
  rebuild the draft from `SKILL.md` and ask for confirmation again.
- If write access or confirmation is missing, fall back to `draft-only`.
- If the displayed draft is stale because the PR diff changed, rebuild
  it from `SKILL.md` and ask for confirmation again. If the draft
  depended on discussion data, treat relevant discussion changes the
  same way.

## Posting Rules

- Use inline comments only when a point belongs to a specific changed
  file and diff line.
- Reuse the latest user-approved draft artifact from `SKILL.md`, not
  ad-hoc in-memory state, then finalize it into one canonical review
  before writing anything to GitHub.
- Submit only from the `draft_id` shown in the latest displayed draft
  preview.
- Never submit a draft artifact that preflight cleanup marked
  contaminated by prohibited runtime validation.
- During submission, only exact GitHub diff positions may be added
  silently. If anchor validation would drop or relocate any visible
  review point, stop using that draft, show the refreshed draft, and
  get confirmation again.
- If the current PR diff no longer matches the displayed draft, stop
  using that draft, rebuild the draft, show the refreshed draft, and
  get confirmation again. If the draft depended on discussion data,
  apply the same rule to relevant discussion changes.
- Build the full review locally before writing anything to GitHub.
- Submit the review through one `POST /pulls/{pr}/reviews` request, not
  as separate standalone comments.

## Review Submission Flow

0. Bootstrap PR identity and artifact paths.

```bash
gh auth status
gh pr view <pr-url> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,reviewDecision
gh pr view <pr-number> -R <owner/repo> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,reviewDecision
git rev-parse --is-inside-work-tree
git remote -v
```

Resolve `PR_REPO=OWNER/REPO` using the rules from `SKILL.md` before
continuing. If the first `gh pr view` call uses a full PR URL to discover
`PR_REPO`, use the returned numeric PR number for later commands.

Use the resolved `PR_REPO` on every later `gh pr` command and every
`gh api` path below. Do not infer the repository again from the current
checkout. This workflow assumes the default `github.com` host, so keep
`PR_REPO` as `OWNER/REPO`, not `[HOST/]OWNER/REPO`.

Split `PR_REPO` once for explicit GitHub API paths:

```bash
PR_OWNER="${PR_REPO%%/*}"
PR_NAME="${PR_REPO#*/}"
```

Normalize `PR_REPO` by replacing `/` with `__`, then define the draft
artifact path and the derived review-payload path:

```bash
PR_NUMBER="<resolved-pr-number>"
PR_REPO_SAFE="${PR_REPO//\//__}"
REVIEW_DRAFT_DIR="${TMPDIR:-/tmp}/codex-gh-pr-review"
REVIEW_DRAFT_FILE="$REVIEW_DRAFT_DIR/${PR_REPO_SAFE}__pr-${PR_NUMBER}.json"
REVIEW_PAYLOAD_FILE="$REVIEW_DRAFT_DIR/${PR_REPO_SAFE}__pr-${PR_NUMBER}__review.json"
RUNTIME_STATE_DIR="${TMPDIR:-/tmp}/codex-gh-pr-review-runtime"
RUNTIME_STATE_FILE="$RUNTIME_STATE_DIR/${PR_REPO_SAFE}__pr-${PR_NUMBER}.json"
```

Bootstrap is path resolution only. Do not load `REVIEW_DRAFT_FILE`, use
local files as review context, validate draft freshness, finalize
anchors, or submit anything in this step.

1. Run `Preflight Cleanup` from `SKILL.md`.

- Run it immediately after step `0`, using the resolved `PR_REPO`,
  `PR_NUMBER`, `PR_REPO_SAFE`, `REVIEW_DRAFT_FILE`, and
  `RUNTIME_STATE_FILE`.
- If review-owned leftover runtime-validation state is found, clean it
  up first using the ownership and contamination rules from `SKILL.md`.
- Load the PR-scoped runtime ownership record described in `SKILL.md`
  first. If it is missing, fall back to scanning the runtime temp root
  for matching review-owned markers.
- Remove that runtime ownership record only after the cleanup it
  describes succeeds.
- If the draft is not already treated as contaminated, preflight may do
  a metadata-only read of `REVIEW_DRAFT_FILE` to inspect hidden
  recovery fields such as `context_mode`. Do not trust visible review
  text or comment bodies during that read.
- If prohibited runtime validation may have influenced visible draft
  content or review reasoning, invalidate the displayed draft and
  `REVIEW_DRAFT_FILE` before any freshness checks. Delete or quarantine
  it, rebuild from clean static inputs, show the refreshed draft, and
  ask for confirmation again. Do not consult stored `context_mode` to
  salvage that contaminated draft.
- If only local review context was contaminated, but the visible draft
  and review reasoning remain trusted, discard or recreate `REVIEW_TREE`
  before relying on local files.
- Only in that trusted-draft case may `context_mode` decide recovery:
  `github-only` and `review-tree-optional` may continue from GitHub
  metadata and fetched diff text without local files; if
  `context_mode` is `review-tree-required`, stop and refresh the draft
  from a clean `REVIEW_TREE`.
- If later submit-time recovery or draft refresh needs local files,
  apply the same `REVIEW_TREE` rule from `SKILL.md` before relying on
  them. If local context is available, prefer a temporary review
  worktree created under `SKILL.md`; otherwise continue from GitHub diff
  and metadata. Do not mutate the user's checkout just to make it match
  the PR head. Carry `REVIEW_TREE_CREATED=0` through the submission flow
  and set it to `1` only after `git worktree add` succeeds under the
  `SKILL.md` local-context rules.

2. Confirm the displayed draft is still current.

Load and parse `REVIEW_DRAFT_FILE` first. It must contain the latest
approved `draft_id` and the exact canonical draft schema from
`SKILL.md`: `pr_repo`, `pr_number`, `commit_id`, `base_ref_name`,
`context_mode`, `diff_fingerprint`, optional
`discussion_fingerprint`, `event`, `body`, and `comments`. Each stored
inline comment must include hidden `anchor` metadata sufficient to
relocate it later: `line_type`, `left_line`, `right_line`,
`hunk_index`, `line_index_in_hunk`, `hunk_header`, `prefixed_line`,
`context_before`, and `context_after`. Use the semantics defined in
`SKILL.md`: `left_line` is the absolute pre-image line number or
`null`, `right_line` is the absolute post-image line number or `null`,
`hunk_index` is zero-based within the file, and `line_index_in_hunk`
is zero-based within the hunk excluding the hunk header. If the
artifact is missing, unreadable, malformed, contaminated, quarantined,
or its `draft_id` does not match the latest displayed draft preview, do
not submit it. Rebuild the draft and ask for confirmation again.
- After preflight keeps the draft trusted, treat stored `context_mode`
  as authoritative for later submit-time recovery: `github-only` and
  `review-tree-optional` may continue without local files;
  `review-tree-required` may not.

Then re-read the current PR metadata and compare it to the review
draft's stored `commit_id`, `base_ref_name`, and `diff_fingerprint`.
Recompute `diff_fingerprint` from the normalized exact unified diff, for
example `gh pr diff <pr> -R <owner/repo> --patch --color=never`, not
from the changed-file list alone. If the draft used discussion data for
reviewing existing comments, refresh that discussion data and compare it
to the stored `discussion_fingerprint` too. The matching fetched patch
becomes the canonical anchor source for this submission; the draft does
not need to retain the original patch text.

```bash
gh pr view <pr> -R <owner/repo> --json baseRefName,headRefOid
gh pr diff <pr> -R <owner/repo> --patch --color=never
# only when the approved draft used discussion data
gh pr view <pr> -R <owner/repo> --comments
gh api --paginate "repos/$PR_OWNER/$PR_NAME/issues/$PR_NUMBER/comments?per_page=100"
gh api --paginate "repos/$PR_OWNER/$PR_NAME/pulls/$PR_NUMBER/comments?per_page=100"
gh api --paginate "repos/$PR_OWNER/$PR_NAME/pulls/$PR_NUMBER/reviews?per_page=100"
```

If the current `headRefOid`, `baseRefName`, `diff_fingerprint`, or
required `discussion_fingerprint` differs from the review draft, do not
submit it. Rerun the `SKILL.md` draft-building steps so the reviewed
draft and stored metadata are recalculated against current PR state,
rebuild the temporary review worktree if one was used, then ask for
confirmation again. Likewise, if `context_mode` is
`review-tree-required` and a clean `REVIEW_TREE` cannot be created when
the draft needs any refresh or local-context recovery, do not submit it.

3. Finalize the approved draft into one canonical review.

Compute exact GitHub diff positions for the inline comments kept in the
draft. If finalization drops or relocates any visible review point, or
if an inline comment must be moved into a `Promoted Findings` section in
the final review body because it cannot be anchored reliably, stop, show
the refreshed draft, and ask for confirmation again.

If finalization succeeds without changing visible review content,
overwrite `REVIEW_DRAFT_FILE` in place with the finalized canonical
review. Add exact GitHub `position` values to each retained inline
comment and keep the existing `draft_id`. After this write,
`REVIEW_DRAFT_FILE` itself is the only finalized source of truth used to
build the GitHub payload.

4. Convert the approved canonical review into one complete review payload.

Create a JSON payload from the approved canonical review by projecting
`REVIEW_DRAFT_FILE` down to the GitHub reviews API schema. Its visible
review content must match the last draft shown to the user. Keep only
the reviewed `commit_id`, the final review `body`, the review `event`,
and a `comments` array only for inline comments that were already
retained in that canonical review. For each retained inline comment,
keep only `path`, `position`, and `body`. Read these values from
`REVIEW_DRAFT_FILE`, not from ad-hoc reassembly. Drop `draft_id`,
`pr_repo`, `pr_number`, `base_ref_name`, `context_mode`,
`diff_fingerprint`, `discussion_fingerprint`, and each comment's
`anchor` metadata from `REVIEW_PAYLOAD_FILE`. `REVIEW_PAYLOAD_FILE`
must contain only top-level `event`, `commit_id`, `body`, and optional
`comments`. Drop every other top-level key from the canonical draft,
including future metadata additions. When anchor failures promoted
findings into the body, the final review body may exceed the normal
summary limit to enumerate only those promoted findings. At this step,
`REVIEW_DRAFT_FILE` must already be the finalized canonical review and
every retained inline comment must already carry its exact GitHub
`position`.

```json
{
  "event": "COMMENT",
  "commit_id": "<reviewed headRefOid>",
  "body": "Concise final review body",
  "comments": [
    {
      "path": "path/to/file",
      "position": 123,
      "body": "Short, concrete review comment"
    }
  ]
}
```

Do not recompute anchors or rewrite comments here. Step 3 already used
the re-fetched exact diff plus each comment's stored `anchor` metadata
to resolve every retained inline comment to one exact GitHub `position`
and wrote those `position` values back into `REVIEW_DRAFT_FILE`. If any
retained inline comment still lacks a `position` at this step, treat
finalization as incomplete, stop, and rebuild or refresh the draft
instead of guessing during submission.

5. Submit the review once.

Materialize `REVIEW_PAYLOAD_FILE` by applying that projection to the
finalized contents of `REVIEW_DRAFT_FILE`, then submit it.
`REVIEW_DRAFT_FILE` remains the only cross-turn source of truth;
`REVIEW_PAYLOAD_FILE` is disposable derived output for the single
GitHub write.

```bash
gh api -X POST "repos/$PR_OWNER/$PR_NAME/pulls/$PR_NUMBER/reviews" --input "$REVIEW_PAYLOAD_FILE"
```

6. After successful submission or after abandoning the review, remove any
temporary review worktree created for it and delete
`REVIEW_DRAFT_FILE`, `REVIEW_PAYLOAD_FILE`, plus `RUNTIME_STATE_FILE`
if it exists.

```bash
if [ "${REVIEW_TREE_CREATED:-0}" = "1" ]; then
  git worktree remove "$REVIEW_TREE" || exit 1
fi
rm -f "$REVIEW_DRAFT_FILE"
rm -f "$REVIEW_PAYLOAD_FILE"
rm -f "$RUNTIME_STATE_FILE"
```

If no temporary review worktree was created, skip the worktree-removal
step. Do not force-remove a dirty temporary review worktree. If
worktree cleanup fails, stop immediately and do not delete
`REVIEW_DRAFT_FILE`, `REVIEW_PAYLOAD_FILE`, or `RUNTIME_STATE_FILE`. If
draft-artifact cleanup
fails, tell the user that stale local draft state remains and rebuild
instead of trusting it on a later submit. If only
`REVIEW_PAYLOAD_FILE` cleanup fails, tell the user that stale derived
local payload state remains and regenerate it from `REVIEW_DRAFT_FILE`
or a refreshed draft instead of trusting it on a later submit. If only
`RUNTIME_STATE_FILE` cleanup fails, tell the user that stale
review-owned runtime cleanup metadata remains and inspect or recreate it
before trusting it on a later preflight.

## Comment Style

- Keep each inline comment short and actionable.
- Use a code suggestion block only when the fix is small and precise.
- Prefer one strong comment over several weak ones on nearby lines.
