---
name: gh-pr-review
description: >-
  Review GitHub.com pull requests reachable through GitHub CLI for bugs,
  behavioral regressions, risky assumptions, and missing focused test
  coverage. Use when the user asks for a PR review or wants a prepared
  review draft submitted to GitHub after explicit confirmation.
---

# GitHub PR Review

Use this skill for GitHub.com pull requests reachable through `gh`.
Focus on correctness, regressions, risky assumptions, and missing
focused tests. Ignore CI status and existing PR discussion. Use static
review only.

## Prerequisites

Before doing anything else:

- `gh` must be installed and `gh auth status` must succeed.
- Escalate all `gh` commands outside the sandbox (E.g. system keychain)
- The input must explicitly identify a GitHub PR on `github.com`.

If a prerequisite fails, stop immediately and tell the user what is
missing. Do not use any fallback: no web browsing, no public GitHub
access, no local checkout review, no general code review, and no
partial review.

## Modes

- `draft-only`: default. Build and show a draft without writing to GitHub.
- `submit-to-github`: only after the user explicitly approves the shown draft.

## Workflow

1. Check prerequisites first. Run `gh auth status` before anything else.
2. Resolve `PR_REPO=OWNER/REPO` and `PR_NUMBER` from explicit input.
3. Create a fresh `REVIEW_WORK_DIR` for a new draft. For
   `submit-to-github`, reuse the approved `REVIEW_WORK_DIR`.

```bash
PR_OWNER="${PR_REPO%%/*}"
PR_NAME="${PR_REPO#*/}"
PR_NUMBER="<resolved-pr-number>"
REVIEW_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-gh-pr-review.XXXXXX")"
REVIEW_DRAFT_FILE="$REVIEW_WORK_DIR/review-draft.json"
REVIEW_PAYLOAD_FILE="$REVIEW_WORK_DIR/review-payload.json"
REVIEW_REPO_DIR="$REVIEW_WORK_DIR/repo"
REVIEW_WORKTREE_DIR="$REVIEW_WORK_DIR/pr"
```

4. Gather the exact PR state:

```bash
gh auth status
gh pr view <pr-url> \
  --json number,url,title,body,baseRefName,headRefOid,isDraft,author
gh pr view <pr-number> -R <owner/repo> \
  --json number,url,title,body,baseRefName,headRefOid,isDraft,author
gh pr diff <pr> -R <owner/repo> --name-only
gh pr diff <pr> -R <owner/repo> --patch --color=never
gh repo clone <owner/repo> "$REVIEW_REPO_DIR" -- --quiet
git -C "$REVIEW_REPO_DIR" fetch --quiet origin \
  "pull/$PR_NUMBER/head:pr-$PR_NUMBER"
git -C "$REVIEW_REPO_DIR" worktree add --quiet \
  "$REVIEW_WORKTREE_DIR" "pr-$PR_NUMBER"
```

Pass `-R <owner/repo>` on later `gh pr` commands and use explicit
`repos/$PR_OWNER/$PR_NAME/...` paths on `gh api` calls.

5. Inspect the change statically:
- Read the PR description, exact patch, and changed-file list first.
- Read extra file context from `REVIEW_WORKTREE_DIR` only when needed.
- Do not build, test, compile, execute scripts, or add repro changes.
- If static evidence is insufficient, write a conditional finding or an
  open question instead of guessing.

Read extra references only when they apply:
- `references/helidon-review.md` for Helidon repositories.
- `references/review-checklist.md` for public APIs, persistence,
  config, auth, concurrency, or build/test wiring.

## Draft Rules

- Findings first, ordered by severity.
- Lead with bugs, regressions, compatibility issues, security issues,
  hidden failures, and missing focused tests.
- Keep comments concrete and high-value. Avoid style-only remarks unless
  they hide a real defect.
- Build one complete draft locally before writing anything to GitHub.
- Default `event` to `COMMENT`.
- Keep the review body concise, usually 2 sentences or fewer, no
  recommendations, no categorization, no action, only summarize the overall state
- Do not use first person. Say `this PR` or `this changeset`.
- If no findings remain, say that explicitly and note residual risk.
- Build exact GitHub diff `position` values while drafting.
- If a point cannot be anchored to an exact diff position, put it in the
  review body.
- Write or overwrite `REVIEW_DRAFT_FILE`. If draft storage fails, stop.

Draft JSON schema:

```json
{
  "draft_id": "<deterministic hash of visible review content>",
  "pr_repo": "owner/repo",
  "pr_number": 123,
  "commit_id": "<reviewed headRefOid>",
  "diff_fingerprint": "<hash of the exact normalized patch>",
  "event": "COMMENT",
  "body": "Concise final review body",
  "comments": [
    {
      "path": "path/to/file",
      "position": 123,
      "body": "Short, concrete review comment",
      "line_hint": "right:123"
    }
  ]
}
```

Preview format:
- Start with `Inline Comments`.
- Number inline comments.
- Show file path, optional `line_hint`, and quoted comment text.
- Then render `---`, `State: <state>`, and the review body

Always display the preview format instead of the normal "Findings" view.
Let the user iterate over the draft in the preview format.

## Submit

Use this flow only when the user explicitly wants `submit-to-github`
and has approved the displayed draft.

1. Reuse the approved `REVIEW_WORK_DIR` and load `REVIEW_DRAFT_FILE`.
2. Re-read the current `headRefOid` and exact patch:

```bash
gh pr view <pr> -R <owner/repo> --json headRefOid
gh pr diff <pr> -R <owner/repo> --patch --color=never
```

3. Recompute the diff fingerprint. If the current commit or fingerprint
   differs from the saved draft, rebuild the draft and ask again.
4. Build `REVIEW_PAYLOAD_FILE` from the saved draft using only `event`,
   `commit_id`, `body`, and optional `comments` with `path`,
   `position`, and `body`.
5. Submit once:

```bash
gh api -X POST "repos/$PR_OWNER/$PR_NAME/pulls/$PR_NUMBER/reviews" --input "$REVIEW_PAYLOAD_FILE"
```

Do not rewrite review text, re-anchor comments, or clean up
`REVIEW_WORK_DIR`. If the draft is missing, malformed, or stale, rebuild
it and ask for confirmation again.
