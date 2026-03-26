# GitHub Submission Workflow

Use this reference only for the `submit-to-github` mode selected in
`SKILL.md`. Use the review-text rules and default event from `SKILL.md`;
this file only covers GitHub-specific mechanics for validating the
approved draft, finalizing one canonical review, and submitting it.

## Preconditions

- This workflow supports pull requests hosted on `github.com` only. If
  the user supplies a PR URL on another host, stop and tell them this
  skill does not support that host.
- Verify a real GitHub write path exists before attempting any write.
- Ask for explicit confirmation before creating a review.
- Load the per-PR draft artifact from
  `${TMPDIR:-/tmp}/codex-gh-pr-review/<pr-repo-safe>__pr-<number>.json`.
  If it is missing, unreadable, or malformed, rebuild the draft from
  `SKILL.md` and ask for confirmation again.
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

1. Verify auth, resolve `PR_REPO`, and load PR context.

```bash
gh auth status
gh pr view <pr-url> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,reviewDecision
gh pr view <pr-number> -R <owner/repo> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,reviewDecision
git rev-parse --is-inside-work-tree
git remote -v
gh pr diff <pr> -R <owner/repo> --name-only
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

Apply the same `REVIEW_TREE` rule from `SKILL.md` before relying on local
files as context. If local context is available, prefer a temporary
review worktree created under `SKILL.md`; otherwise continue from GitHub
diff and metadata. Do not mutate the user's checkout just to make it
match the PR head.

Normalize `PR_REPO` by replacing `/` with `__`, then define the draft
artifact path:

```bash
PR_NUMBER="<resolved-pr-number>"
PR_REPO_SAFE="${PR_REPO//\//__}"
REVIEW_DRAFT_DIR="${TMPDIR:-/tmp}/codex-gh-pr-review"
REVIEW_DRAFT_FILE="$REVIEW_DRAFT_DIR/${PR_REPO_SAFE}__pr-${PR_NUMBER}.json"
```

2. Confirm the displayed draft is still current.

Load and parse `REVIEW_DRAFT_FILE` first. It must contain the latest
approved `draft_id` and the exact canonical draft schema from
`SKILL.md`: `pr_repo`, `pr_number`, `commit_id`, `base_ref_name`,
`diff_fingerprint`, optional `discussion_fingerprint`, `event`, `body`,
and `comments`. Each stored inline comment must include hidden `anchor`
metadata sufficient to relocate it later: `line_type`, `left_line`,
`right_line`, `hunk_index`, `line_index_in_hunk`, `hunk_header`,
`prefixed_line`, `context_before`, and `context_after`. Use the
semantics defined in `SKILL.md`: `left_line` is the absolute pre-image
line number or `null`, `right_line` is the absolute post-image line
number or `null`, `hunk_index` is zero-based within the file, and
`line_index_in_hunk` is zero-based within the hunk excluding the hunk
header. If the artifact is missing, unreadable, malformed, or its
`draft_id` does not match the latest displayed draft preview, do not
submit it. Rebuild the draft and ask for confirmation again.

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
confirmation again.

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
`REVIEW_DRAFT_FILE` itself is the only submit-ready source of truth.

4. Convert the approved canonical review into one complete review payload.

Create a JSON payload from the approved canonical review. Its visible
review content must match the last draft shown to the user. Include the
reviewed `commit_id`, the final review `body`, the review `event`, and a
`comments` array only for inline comments that were already retained in
that canonical review. Read these values from `REVIEW_DRAFT_FILE`, not
from ad-hoc reassembly. When anchor failures promoted findings into the
body, the final review body may exceed the normal summary limit to
enumerate only those promoted findings. At this step,
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

Materialize `review.json` directly from the finalized contents of
`REVIEW_DRAFT_FILE`, then submit it.

```bash
gh api -X POST "repos/$PR_OWNER/$PR_NAME/pulls/$PR_NUMBER/reviews" --input review.json
```

6. After successful submission or after abandoning the review, remove any
temporary review worktree created for it and delete `REVIEW_DRAFT_FILE`.

```bash
git worktree remove "$REVIEW_TREE"
rm -f "$REVIEW_DRAFT_FILE"
```

Do not force-remove a dirty temporary review worktree. If worktree
cleanup fails, stop and tell the user. If draft-artifact cleanup fails,
tell the user that stale local draft state remains and rebuild instead
of trusting it on a later submit.

## Comment Style

- Keep each inline comment short and actionable.
- Use a code suggestion block only when the fix is small and precise.
- Prefer one strong comment over several weak ones on nearby lines.
