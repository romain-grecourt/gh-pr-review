---
name: gh-pr-review
description: >-
  Review GitHub pull requests reachable through GitHub CLI for bugs,
  behavioral regressions, risky assumptions, missing validation, and merge
  risk. Use when the user asks for a PR review, asks to review a specific
  GitHub pull request, requests feedback on review comments for that PR, or
  needs a structured code-review report with concrete findings, risky areas
  that need attention, and file references. Supports both local draft
  previews of the GitHub review text and GitHub submission after explicit
  user confirmation. Do not use this skill for local patch files, pasted
  diffs, or non-GitHub review input. Includes optional Helidon-specific
  review guidance when the repository is Helidon-related.
---

# GitHub PR Review

## Overview

Review GitHub pull requests with a code-review mindset. Prioritize
correctness, regressions, risk, and missing test coverage over style, and
report concrete findings before any summary.

Ignore CI checks, workflow runs, and merge-state summaries for this skill.
If the user wants workflow or check diagnosis, handle that as a separate
task instead of folding it into the PR review.

This skill requires GitHub CLI (`gh`) to be installed, authenticated, and
able to access the target pull request. If that setup is missing, stop and
tell the user this skill cannot proceed until `gh` is working.

If the user only provides a local patch file, a pasted diff, or any other
non-GitHub review input, this skill does not apply. Handle that as a
general code review task instead of trying to force it through this
workflow.

Use two output modes:
- `draft-only`: build a review draft for the target PR and render it
  locally without changing GitHub. In draft mode, inline comments may be
  shown with changed file paths and human line hints instead of final
  GitHub diff positions.
- `submit-to-github`: after explicit user confirmation, finalize that
  reviewed draft into one canonical review payload and submit it.
- The canonical review contains the reviewed `commit_id`, the review
  `event`, the final review `body`, and the final set of inline comments.
- The canonical review also stores the resolved `pr_repo`, `pr_number`,
  `base_ref_name`, a `diff_fingerprint`, and a
  `discussion_fingerprint` so a later submission can detect stale
  diff anchors or stale duplicate-suppression inputs before writing.
- In `draft-only`, duplicate suppression may be light and best-effort.
  When preparing a GitHub submission, run conservative duplicate
  suppression and exact diff-anchor validation against the current PR
  state.
- After a draft is shown, submission may add exact GitHub diff positions
  only. If finalization would suppress, rewrite, add, drop, or relocate
  any visible review point, discard the earlier approval, show the
  refreshed draft, and ask for confirmation again.
- If the reviewed head commit, PR diff, or discussion changes after the
  draft is prepared, discard it, rebuild the draft, show the refreshed
  version, and ask for confirmation again before submitting.

## Gather Context

- Verify `gh` access first, then resolve the target PR and base
  repository, then identify the base branch, head branch, head commit, and
  whether a temporary detached review worktree can be created from a local
  checkout of `PR_REPO`.
- Detect repository-specific rules before reviewing code, then select
  references from this section only:
  - Read [helidon-review.md](./references/helidon-review.md) when the
    repository is Helidon-related, such as repo-level `groupId`, package
    namespaces, or module names starting with `io.helidon`. Do not trigger
    Helidon mode from isolated diff hints alone.
  - Read [review-checklist.md](./references/review-checklist.md) when the
    change touches public APIs, persistence, config, auth, concurrency, or
    build/test wiring.
  - Read
    [github-submit-review.md](./references/github-submit-review.md) only
    when the user explicitly wants `submit-to-github`.
- Resolve the base repository before later review commands:
  - If the user supplies a full PR URL, use that URL for the initial
    `gh pr view` call.
  - If the user supplies only a PR number, prefer an explicit
    `OWNER/REPO` and use `gh pr view <pr> -R <owner/repo>` for the
    initial metadata call.
  - Use `gh repo view --json nameWithOwner` only when the current
    checkout is clearly the intended repository, then feed the resolved
    repo into `gh pr view <pr> -R <owner/repo>`.
  - If the repository is still ambiguous, stop and ask for a PR URL or
    `OWNER/REPO`.
- Load GitHub and local checkout metadata:

```bash
gh auth status
gh repo view --json nameWithOwner   # only when resolving repo from current checkout
gh pr view <pr-url> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,isDraft,author
gh pr view <pr-number> -R <owner/repo> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,isDraft,author
git rev-parse --is-inside-work-tree
git remote -v
```

- Resolve `PR_REPO=OWNER/REPO` from explicit user input, the current
  checkout when appropriate, or the returned PR `url`.
- After resolving `PR_REPO`, pass `-R <owner/repo>` on every later
  `gh pr` command and use `repos/{owner}/{repo}/...` on every `gh api`
  call. Do not fall back to whatever repository happens to be checked out
  locally.
- Pull the changed-file list early so review time stays focused:

```bash
gh pr diff <pr> -R <owner/repo> --name-only
```

- If the user asks for feedback on existing review comments or
  unresolved discussion, load the PR discussion before inspecting code
  so the review can test whether each concern still applies on the
  current head.

- In `draft-only`, loading existing PR discussion is optional. Before
  finalizing a review for GitHub submission, load the existing PR
  discussion so conservative duplicate suppression happens against the
  latest available state:

```bash
gh pr view <pr> -R <owner/repo> --comments
gh api --paginate "repos/{owner}/{repo}/issues/{pr}/comments?per_page=100"
gh api --paginate "repos/{owner}/{repo}/pulls/{pr}/comments?per_page=100"
gh api --paginate "repos/{owner}/{repo}/pulls/{pr}/reviews?per_page=100"
```

- Treat the paginated `gh api` results above as best-effort
  duplicate-check and discussion-review inputs. They may not capture
  complete thread state, so use them conservatively and suppress only
  obvious duplicates.
  `gh pr view <pr> -R <owner/repo> --comments` is only a readable summary
  and should not control suppression decisions.

- When local filesystem context is used, define `REVIEW_TREE` as the only
  local filesystem allowed for surrounding implementation,
  configuration, and test context.
- If the current checkout clearly belongs to `PR_REPO` and a detached
  review worktree can be created without extra friction, prefer creating
  a temporary detached review worktree at the exact PR head and use that
  as `REVIEW_TREE`, even when the current checkout already points at the
  same commit:

```bash
git cat-file -e "${headRefOid}^{commit}" 2>/dev/null || \
  git fetch --no-tags <remote-for-pr-repo> "pull/<pr>/head"
REVIEW_HEAD=$(git rev-parse "${headRefOid}^{commit}" 2>/dev/null || git rev-parse FETCH_HEAD)
REVIEW_TREE=$(mktemp -d "${TMPDIR:-/tmp}/codex-pr-review.XXXXXX")
git worktree add --detach "$REVIEW_TREE" "$REVIEW_HEAD"
```

- Determine `<remote-for-pr-repo>` by matching a `git remote -v` fetch URL
  to `PR_REPO`.
- After fetching, if `REVIEW_HEAD` does not equal `headRefOid`, refresh PR
  metadata and restart context gathering. The PR changed during setup.
- Never use the user's current checkout itself for review context, and do
  not mix context from the user's checkout with context from a temporary
  review worktree.
- If the local checkout is not clearly the same repository as `PR_REPO`,
  if the fetch or worktree step fails, or if local setup would be
  inconvenient, do not use local files as surrounding context. Review
  from `gh pr diff` and GitHub metadata, and say the local context is
  limited.
- After the review is finished or abandoned, remove any temporary review
  worktree created for it:

```bash
git worktree remove "$REVIEW_TREE"
```

- Do not force-remove a dirty temporary review worktree. If cleanup fails,
  stop and tell the user.
- Do not auto-run `gh pr checkout`, `git switch`, or other commands that
  mutate the user's checkout just to align it. A detached temporary review
  worktree is preferred for local context because it does not disturb the
  current checkout and avoids ambiguity about local edits.
- If `gh` is unavailable, unauthenticated, or cannot access the PR, stop
  and tell the user this skill requires a working GitHub CLI setup.

## Inspect the Change

- Read the PR description for intended behavior, rollout notes, linked
  issues, and claimed test coverage.
- Inspect the diff, then open the surrounding implementation and related
  tests only from `REVIEW_TREE`. If no `REVIEW_TREE` is available, use the
  GitHub diff and metadata instead, and note that the local context is
  limited.
- When no `REVIEW_TREE` is available, do not open stale local files for
  context and do not run repo-wide search in the user's checkout for PR
  reasoning.
- In Java/Maven repos, inspect affected `pom.xml`, `module-info.java`, and
  the nearest tests together with the production code, but only from
  `REVIEW_TREE` when local context is used.
- Keep the review static and fast. Do not run tests, execute scripts, add
  temporary repro changes, instrument the code, or otherwise exercise the
  PR. Analyze behavior from the diff, surrounding code, and existing tests,
  and only trace behavior when that reasoning is cheap. Do deeper or more
  expensive analysis only when the user explicitly asks for it.

- Use fast repo search only inside `REVIEW_TREE` to find adjacent call
  sites, tests, and related configuration:

```bash
cd "$REVIEW_TREE"
rg -n "<symbol-or-config-key>" .
rg --files | rg "Test|IT|Spec"
```

## Prioritize Findings

- Lead with issues that could ship a bug, break compatibility, corrupt
  data, weaken security, or hide failing behavior.
- Analyze behavior, not just structure, but keep tracing cheap and
  grounded in the diff, surrounding code, and existing tests.
- Flag missing or weak tests when the change meaningfully alters behavior
  and existing coverage does not cover the new path.
- Treat style issues as low priority unless they obscure a real defect or
  violate enforced project rules.
- Distinguish confirmed findings from open questions. If the evidence is
  incomplete, say so explicitly.
- Keep comments concrete and high-value. Keep speculative concerns, broad
  design notes, and non-actionable style remarks out of inline comments.
- Do not post comments about routine local test results. Mention tests
  only when the lack of coverage is itself part of the finding, or when a
  validation gap materially changes the risk.

## Write the Review

- Present findings first, ordered by severity.
- Build a review draft before rendering anything. When preparing a
  GitHub submission, finalize one canonical review from the latest
  user-visible draft. It contains the reviewed `commit_id`, the review
  `event`, the final review `body`, and the final set of inline
  comments.
- Store enough metadata with the draft to prove it is still current
  later: the resolved `pr_repo`, `pr_number`, `base_ref_name`, a
  `diff_fingerprint` from the exact diff or changed-file set reviewed,
  and a `discussion_fingerprint` from the discussion data used for
  duplicate suppression or existing-comment review. If discussion was
  not loaded yet, store `discussion_fingerprint=not-loaded`.
- Give each finding a short title plus the impact, supporting evidence,
  and a concrete file reference.
- Use simple, tight prose: short sentences, short paragraphs, and usually
  1-3 sentences per finding. Avoid long narrative walkthroughs.
- Keep any summary brief and only after the findings. If the diff touches
  behavior that deserves extra attention even without a confirmed bug, add
  a short note calling that out.
- If no findings remain, state that explicitly and call out residual risk
  such as unclear migration behavior, missing focused coverage, or missing
  production evidence.
- Use inline comments for file-specific findings when the point belongs to
  a specific changed file and diff line. Start each inline comment with a
  short statement of the core fact, then use a new paragraph for impact or
  evidence.
- In `draft-only`, duplicate suppression may be light and best-effort.
  Before submission, suppress only points clearly already covered in the
  PR discussion. Dedupe the underlying point, not just exact wording. If
  the available discussion data is incomplete or the status is
  ambiguous, keep the point. Repost only when a new revision introduces
  a materially different instance of the issue. If this finalization
  changes any visible review content, refresh the draft and ask for
  confirmation again.
- In `draft-only`, show the changed file path and a human line hint when
  helpful. Compute exact GitHub diff positions only when preparing a
  submission. If a file-specific point cannot be anchored reliably at
  submission time, move it into the final review body, refresh the
  draft, and ask for confirmation again instead of guessing.
- Keep the final review body synthetic, concise, and non-duplicative. It
  should state the overall shape of the findings in simple language, stay
  at 2 sentences or fewer unless the user asks for more, and never
  repeat, list, or point back to the inline comments.
- Default the review state/event to `COMMENT` unless the user explicitly
  requests another state.
- Do not use first person in the review text.
- Say `this PR` or `this changeset`, not `this branch`, unless the user
  explicitly asks for branch wording.
- Do not call findings blocking or non-blocking, and do not make merge
  recommendations, unless the user explicitly asks for that judgment.

For `draft-only`, always render the full current draft preview when
iterating with the user. Use this layout:

- Show only the rendered preview by default. Do not include the raw GitHub
  payload unless the user explicitly asks for it.
- Use light ANSI art only for section banners and separators; keep comment
  text plain.
- Start with an `Inline Comments` section banner.
- Put a visible delimiter line above each inline comment block; do not
  rely on blank lines alone.
- Number the inline comments.
- For each inline comment block:
  - show the changed file path
  - include a human line hint when it helps orient the reader
  - include a short `diff` excerpt when it helps orient the reader
  - show the exact inline comment text as a markdown blockquote
- After the inline comments, render `---`, then `State: <state>`, then
  the final review body directly below it with no extra `Comment:` label.
- Render the latest user-visible draft. If submission finalization later
  changes any visible review content, show the refreshed draft before
  asking for confirmation again.

## Handle Common Variants

- Review a single PR: inspect GitHub metadata, diff, and targeted
  files.
- Review existing PR comments: load the latest PR comments and reviews,
  treat them as input, and assess whether each concern still applies on
  the current head. Call out agreements, disagreements, and unresolved
  risk instead of drafting a second review that ignores the discussion
  already on the PR.
- Review stacked or large changes: break the review into commits or
  subsystems, or explicitly scope the review to the highest-risk files
  and state that the review is scoped, then aggregate only the
  highest-value findings.
- Review after comments or revisions: re-check only the touched files and
  any areas affected by the requested change; avoid re-reviewing unchanged
  code unless the fix widened the risk surface.
- Submit a review to GitHub: reuse the same analysis bar, then follow
  [github-submit-review.md](./references/github-submit-review.md) so
  the inline comments and final review body are submitted through one
  complete review payload instead of as disconnected messages.
