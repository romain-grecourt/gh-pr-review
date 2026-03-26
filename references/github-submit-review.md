# GitHub Submission Workflow

Use this reference only for the `submit-to-github` mode selected in
`SKILL.md`. Use the review-text rules and default event from `SKILL.md`;
this file only covers GitHub-specific mechanics for validating the
approved draft, finalizing one canonical review, and submitting it.

## Preconditions

- Verify a real GitHub write path exists before attempting any write.
- Ask for explicit confirmation before creating a review.
- If write access or confirmation is missing, fall back to `draft-only`.
- If the displayed draft is stale because the PR diff or discussion
  changed, rebuild it from `SKILL.md` and ask for confirmation again.

## Posting Rules

- Use inline comments only when a point belongs to a specific changed
  file and diff line.
- Reuse the latest user-approved draft from `SKILL.md`, then finalize it
  into one canonical review before writing anything to GitHub.
- During submission, only exact GitHub diff positions may be added
  silently. If conservative duplicate suppression or anchor validation
  would suppress, rewrite, add, drop, or relocate any visible review
  point, stop using that draft, show the refreshed draft, and get
  confirmation again.
- If the current PR diff or discussion no longer matches the displayed
  draft, stop using that draft, rebuild the draft, show the refreshed
  draft, and get confirmation again.
- Build the full review locally before writing anything to GitHub.
- Submit the review through one `POST /pulls/{pr}/reviews` request, not
  as separate standalone comments.

## Review Submission Flow

1. Verify auth, resolve `PR_REPO`, and load PR context.

```bash
gh auth status
gh repo view --json nameWithOwner   # only when resolving repo from current checkout
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
checkout.

Apply the same `REVIEW_TREE` rule from `SKILL.md` before relying on local
files as context. If local context is available, prefer a temporary
review worktree created under `SKILL.md`; otherwise continue from GitHub
diff and metadata. Do not mutate the user's checkout just to make it
match the PR head.

2. Confirm the displayed draft is still current.

Re-read the current PR metadata before submission and compare it to the
review draft's stored `commit_id`, `base_ref_name`, and
`diff_fingerprint`. If the draft used discussion data for duplicate
suppression or for reviewing existing comments, refresh that discussion
data and compare it to the stored `discussion_fingerprint` too.

```bash
gh pr view <pr> -R <owner/repo> --json baseRefName,headRefOid
gh pr diff <pr> -R <owner/repo> --name-only
gh pr view <pr> -R <owner/repo> --comments
gh api --paginate "repos/{owner}/{repo}/issues/{pr}/comments?per_page=100"
gh api --paginate "repos/{owner}/{repo}/pulls/{pr}/comments?per_page=100"
gh api --paginate "repos/{owner}/{repo}/pulls/{pr}/reviews?per_page=100"
```

If the current `headRefOid`, `baseRefName`, `diff_fingerprint`, or
required `discussion_fingerprint` differs from the review draft, do not
submit it. Rerun the `SKILL.md` draft-building steps so the reviewed
draft and stored metadata are recalculated against current PR state,
rebuild the temporary review worktree if one was used, then ask for
confirmation again.

3. Finalize the approved draft into one canonical review.

Run conservative duplicate suppression against the latest available PR
discussion and compute exact GitHub diff positions for the inline
comments kept in the draft. If finalization suppresses, rewrites, drops,
or relocates any visible review point, or if an inline comment must be
moved into the final review body because it cannot be anchored reliably,
stop, show the refreshed draft, and ask for confirmation again.

4. Convert the approved canonical review into one complete review payload.

Create a JSON payload from the approved canonical review. Its visible
review content must match the last draft shown to the user. Include the
reviewed `commit_id`, the final review `body`, the review `event`, and a
`comments` array only for inline comments that were already retained in
that canonical review.

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

Use the unified diff used to prepare the draft, or refresh it only to
compute the GitHub diff position for the already-approved inline
comments when the current `headRefOid`, `baseRefName`, and
`diff_fingerprint` still match the approved draft, and when any
required `discussion_fingerprint` still matches too. Use the diff
position, not the absolute file line number. If an approved inline
comment can no longer be anchored reliably, move it into the final
review body, show the refreshed draft, and ask for confirmation again
instead of guessing during submission.

5. Submit the review once.

```bash
gh api -X POST "repos/{owner}/{repo}/pulls/{pr}/reviews" --input review.json
```

6. After successful submission or after abandoning the review, remove any
temporary review worktree created for it.

```bash
git worktree remove "$REVIEW_TREE"
```

Do not force-remove a dirty temporary review worktree. If cleanup fails,
stop and tell the user.

## Comment Style

- Keep each inline comment short and actionable.
- Use a code suggestion block only when the fix is small and precise.
- Prefer one strong comment over several weak ones on nearby lines.
