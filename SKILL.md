---
name: gh-pr-review
description: >-
  Review GitHub.com pull requests reachable through GitHub CLI for bugs,
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

This skill supports pull requests hosted on `github.com` only. If the
user supplies a PR URL on another host, or needs GitHub Enterprise or
other non-default host support, stop and tell the user this skill does
not support that host.

If the user only provides a local patch file, a pasted diff, or any other
non-GitHub review input, this skill does not apply. Handle that as a
general code review task instead of trying to force it through this
workflow.

Use three independent axes:
- Analysis policy: `static-review`.
  This policy governs how evidence is gathered and applies to all
  ordinary uses of this skill.
- Output mode: `draft-only`.
  Build and render a local review draft without changing GitHub. In
  draft mode, inline comments may be shown with changed file paths and
  human line hints instead of final GitHub diff positions.
- Output mode: `submit-to-github`.
  After explicit user confirmation, finalize and submit an already
  approved review draft to GitHub.
- Review scope: `ordinary-pr-review` or `discussion-review`.
  This scope governs whether prior PR discussion is ignored or used as
  best-effort input for reassessing visible concerns.
- `submit-to-github` changes only how the review is finalized and
  submitted. It does not relax `static-review`.
- `discussion-review` is a scope variant, not a third output mode.
- Unless explicitly requested otherwise, `discussion-review` defaults to
  `draft-only`.
- If the user wants runtime validation, builds, tests, or repro
  execution, treat that as a separate opt-in task outside this skill.
- Ordinary PR review ignores existing PR discussion by default. Do not
  load prior comments or suppress duplicates unless the user explicitly
  asks to assess existing review comments or unresolved discussion.
- When the user explicitly asks to assess existing review comments or
  unresolved discussion, treat that as `discussion-review` scope. Use
  visible GitHub comments and reviews as best-effort input and
  classify each concern as `still applies`, `does not apply`, or
  `unclear from available GitHub data`.
- The canonical review contains the reviewed `commit_id`, the review
  `event`, the final review `body`, and the final set of inline comments.
- The canonical review also stores the resolved `pr_repo`, `pr_number`,
  `base_ref_name`, a `context_mode`, a `diff_fingerprint`, and, only
  when the review depended on discussion data, a
  `discussion_fingerprint` so a later submission can detect stale
  inputs before writing.
- `context_mode` is one of `github-only`, `review-tree-optional`, or
  `review-tree-required`.
- Use `github-only` when no local filesystem context shaped the visible
  draft.
- Use `review-tree-optional` when local files were consulted, but the
  visible draft can still be revalidated from GitHub diff, metadata,
  and stored discussion artifacts alone.
- Use `review-tree-required` when any visible draft content depends on
  clean `REVIEW_TREE` context that cannot be reconstructed safely from
  GitHub artifacts alone.
- Persist the latest displayed canonical draft outside the repo as
  `${TMPDIR:-/tmp}/codex-gh-pr-review/<pr-repo-safe>__pr-<number>.json`,
  where `<pr-repo-safe>` is the resolved `PR_REPO` with `/` replaced by
  `__`. Treat that artifact as the only cross-turn source of truth for
  the draft-to-submit handoff.
- If prohibited runtime validation may have influenced that artifact or
  the visible draft it represents, treat it as contaminated, do not
  reuse it, and rebuild from clean static inputs before any submit
  path.
- Any separate `review.json` payload file used for submission is a
  disposable derived artifact only. Rebuild it from the finalized draft
  artifact when needed, and do not treat it as cross-turn state.
- During submit-time finalization, overwrite that same artifact with the
  finalized canonical review used for submission. Hidden fields such as
  exact GitHub diff `position` values may be added in place. If
  finalization would change any visible review content, stop using that
  artifact, refresh the draft, and ask for confirmation again instead.
- Derive `diff_fingerprint` from the exact unified diff reviewed, such
  as `gh pr diff <pr> -R <owner/repo> --patch --color=never`, normalized
  consistently before hashing. Do not derive it from the changed-file
  list alone.
- The draft does not need to retain the full patch text. During
  submission, re-fetch the normalized exact unified diff, verify that it
  still hashes to `diff_fingerprint`, and use that fetched patch as the
  only source for exact GitHub diff positions. If the hash differs,
  rebuild the draft.
- In ordinary PR review, do not suppress points against existing PR
  discussion. Before submission, only validate the approved draft
  against the current diff and compute exact diff anchors.
- After a draft is shown, submission may add exact GitHub diff positions
  only. If finalization would drop or relocate any visible review point,
  discard the earlier approval, show the refreshed draft, and ask for
  confirmation again.
- If the reviewed head commit or PR diff changes after the draft is
  prepared, discard it, rebuild the draft, show the refreshed version,
  and ask for confirmation again before submitting. If the draft used
  discussion data, treat relevant discussion changes the same way.

## Hard Constraints

- Use the `static-review` analysis policy for both output modes unless
  the user explicitly asks for a separate runtime-validation task.
- In `static-review`, do not use commands or runtimes to build, test,
  compile, interpret, fuzz, or otherwise execute repository code,
  generated project outputs, or temporary repro code derived from the
  PR.
- Generic helper tooling is allowed only for these non-executing inputs
  and outputs: review draft JSON, review payload JSON, normalized
  unified diff text fetched from GitHub, and fetched GitHub metadata or
  discussion data used by this skill.
- This exception does not allow helper tooling over repository source
  files, copied code snippets, generated projects, temporary repro
  code, or extracted code samples from the PR.
- Under this exception, tooling may parse, transform, hash, relocate,
  or serialize review artifacts, but must not import, evaluate,
  compile, test, or run repository code.
- Disallowed examples when they exercise the PR include `mvn`,
  `gradle`, `npm`, `pnpm`, `yarn`, `pytest`, `go test`, `cargo test`,
  repository scripts, and ad hoc `java`, `javac`, `python`, or `node`
  repro commands.
- In this skill, "trace behavior" means static reasoning only: inspect
  the diff, surrounding code, call sites, configuration, existing tests,
  and fixtures without executing them.
- If static evidence is insufficient, write a conditional finding or
  open question, or ask the user whether they want opt-in runtime
  validation as a separate task. Do not self-authorize runtime checks.
- If runtime validation was started anyway, immediately create or update
  a PR-scoped runtime ownership record under
  `${TMPDIR:-/tmp}/codex-gh-pr-review-runtime/`, for example
  `<pr-repo-safe>__pr-<number>.json`, with the marker, PID, command,
  cwd, and any temp paths created for that validation.
- Then terminate any validation process, session, or background job you
  started for that validation, wait for it to exit when practical, and
  clean up temporary repro files or scratch artifacts created only for
  that validation when safe.
- Do not kill user-owned processes or delete non-ephemeral files.
- If cleanup cannot be completed quickly, disclose what is still running
  or what temporary state remains, then return to static review.

## Preflight Cleanup

- Before starting or resuming a review, detect review-owned leftover
  runtime-validation state from an earlier interrupted attempt.
- This includes background jobs, long-running sessions, temporary repro
  files, scratch classes, and other ephemeral artifacts created only
  for prohibited runtime validation.
- Any accidental runtime-validation process or scratch artifact created
  by this skill must use a review-owned marker derived from the PR,
  such as `codex-gh-pr-review-runtime-<pr-repo-safe>-<draft-id>`.
- Persist ownership metadata for that runtime state immediately in a
  PR-scoped JSON record under
  `${TMPDIR:-/tmp}/codex-gh-pr-review-runtime/`, for example
  `<pr-repo-safe>__pr-<number>.json`. If the PR is not yet fully
  resolved, use a session-scoped placeholder in the same directory and
  rename it once `PR_REPO` and `PR_NUMBER` are known.
- Store review-owned scratch artifacts only under a dedicated temp root,
  for example `${TMPDIR:-/tmp}/codex-gh-pr-review-runtime/`.
- That record must include at least the review-owned marker, PID,
  command, cwd, and any temp paths created for the prohibited runtime
  validation.
- During preflight cleanup, load that record first. If it is missing,
  fall back to scanning the runtime temp root for matching markers.
- If found, terminate or clean them up using the same ownership rules as
  the recovery path before continuing.
- Remove the runtime ownership record only after the cleanup it
  describes succeeds.
- During preflight cleanup, only terminate processes and remove files
  carrying that review-owned marker or recorded ownership metadata.
- If prohibited runtime validation touched a temporary review worktree,
  local checkout clone, or any local files being used as review context,
  treat that local context as contaminated.
- Do not continue review reasoning from contaminated local context.
- If a contaminated `REVIEW_TREE` exists, remove it and recreate it from
  the PR head before using local context again.
- If prohibited runtime validation may have influenced any visible draft
  content or review reasoning, treat the displayed draft and the stored
  per-PR draft artifact as contaminated too.
- If unsure, fail closed and treat the draft as contaminated.
- Do not preview, finalize, or submit a contaminated draft. Delete it
  or move it aside outside the active draft path, rebuild from clean
  static inputs, and require fresh user confirmation before any
  submission.
- If clean recreation is inconvenient or uncertain, fall back to GitHub
  diff and metadata only and state that local context is unavailable.
- Do not kill user-owned processes or delete non-ephemeral files.
- If cleanup cannot be completed quickly, disclose what remains and
  continue only with static review.

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
  - Because this skill is scoped to `github.com`, use `OWNER/REPO`
    selectors, not `[HOST/]OWNER/REPO`.
  - If the user supplies a full PR URL, use that URL for the initial
    `gh pr view` call.
  - If the user supplies only a PR number, prefer an explicit
    `OWNER/REPO` and use `gh pr view <pr> -R <owner/repo>` for the
    initial metadata call.
  - If the user supplies only a PR number and no explicit `OWNER/REPO`,
    stop and ask for a full PR URL or `OWNER/REPO`. Do not infer the
    repository from the current checkout.
- Load GitHub and local checkout metadata:

```bash
gh auth status
gh pr view <pr-url> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,isDraft,author
gh pr view <pr-number> -R <owner/repo> \
  --json number,url,title,body,baseRefName,headRefName,headRefOid,isDraft,author
git rev-parse --is-inside-work-tree
git remote -v
```

- Resolve `PR_REPO=OWNER/REPO` from explicit user input or the returned
  PR `url`.
- Split `PR_REPO` once and reuse explicit path variables on every later
  `gh api` call:

```bash
PR_OWNER="${PR_REPO%%/*}"
PR_NAME="${PR_REPO#*/}"
PR_NUMBER="<resolved-pr-number>"
```

- After resolving `PR_REPO`, pass `-R <owner/repo>` on every later
  `gh pr` command and use explicit `repos/$PR_OWNER/$PR_NAME/...` paths
  on every `gh api` call. This skill assumes the default `github.com`
  host on every later `gh` and `gh api` call. Do not fall back to
  whatever repository happens to be checked out locally, and do not rely
  on `gh api` placeholder substitution from the current checkout.
- Pull the changed-file list early so review time stays focused:

```bash
gh pr diff <pr> -R <owner/repo> --name-only
```

- If the user asks for feedback on existing review comments or
  unresolved discussion, load the PR discussion before inspecting code
  so the review can test whether each concern still applies on the
  current head.

- For `ordinary-pr-review`, whether `draft-only` or `submit-to-github`,
  skip discussion loading and do not suppress duplicates against prior
  comments. Load discussion only for explicit `discussion-review`
  requests:

```bash
gh pr view <pr> -R <owner/repo> --comments
gh api --paginate "repos/$PR_OWNER/$PR_NAME/issues/$PR_NUMBER/comments?per_page=100"
gh api --paginate "repos/$PR_OWNER/$PR_NAME/pulls/$PR_NUMBER/comments?per_page=100"
gh api --paginate "repos/$PR_OWNER/$PR_NAME/pulls/$PR_NUMBER/reviews?per_page=100"
```

- Treat the paginated `gh api` results above as best-effort
  discussion-review inputs. They may not capture complete thread state,
  so use them to classify visible concerns only as `still applies`,
  `does not apply`, or `unclear from available GitHub data`.
  `gh pr view <pr> -R <owner/repo> --comments` is only a readable summary
  and should not control those classifications by itself.

- When local filesystem context is used, define `REVIEW_TREE` as the only
  local filesystem allowed for surrounding implementation,
  configuration, and test context.
- Never use a contaminated or previously exercised `REVIEW_TREE` for
  static review.
- If the current checkout clearly belongs to `PR_REPO` and a detached
  review worktree can be created without extra friction, prefer creating
  a temporary detached review worktree at the exact PR head and use that
  as `REVIEW_TREE`, even when the current checkout already points at the
  same commit:

```bash
REVIEW_TREE_CREATED=0
git cat-file -e "${headRefOid}^{commit}" 2>/dev/null || \
  git fetch --no-tags <remote-for-pr-repo> "pull/<pr>/head"
REVIEW_HEAD=$(git rev-parse "${headRefOid}^{commit}" 2>/dev/null || git rev-parse FETCH_HEAD)
REVIEW_TREE=$(mktemp -d "${TMPDIR:-/tmp}/codex-pr-review.XXXXXX")
git worktree add --detach "$REVIEW_TREE" "$REVIEW_HEAD"
REVIEW_TREE_CREATED=1
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
if [ "${REVIEW_TREE_CREATED:-0}" = "1" ]; then
  git worktree remove "$REVIEW_TREE"
fi
```

- If no temporary review worktree was created, skip worktree cleanup.
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
  PR.
- In this skill, cheap tracing means static inspection only: follow code
  paths in the diff, inspect adjacent call sites, and compare with
  existing tests, fixtures, and configuration without executing them.
- If static inspection still leaves uncertainty, keep the finding
  conditional or ask whether the user wants opt-in runtime validation as
  a separate task.

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
- Analyze behavior, not just structure, but keep that analysis static,
  cheap, and grounded in the diff, surrounding code, and existing tests.
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
  later: a generated `draft_id`, the resolved `pr_repo`, `pr_number`,
  `commit_id`, `base_ref_name`, `context_mode`, a
  `diff_fingerprint` from the normalized exact unified diff reviewed,
  and, only when discussion data shaped the review, a
  `discussion_fingerprint` from the discussion data used for
  existing-comment review.
- The per-PR draft artifact must be valid JSON with this schema. The
  same file starts as the displayed draft artifact and, after
  submit-time finalization, becomes the finalized canonical draft
  artifact used to build the submission payload:

```json
{
  "draft_id": "<latest approved draft id>",
  "pr_repo": "owner/repo",
  "pr_number": 123,
  "commit_id": "<reviewed headRefOid>",
  "base_ref_name": "main",
  "context_mode": "review-tree-optional",
  "diff_fingerprint": "<normalized exact diff hash>",
  "discussion_fingerprint": "<discussion hash>",
  "event": "COMMENT",
  "body": "Concise final review body",
  "comments": [
    {
      "path": "path/to/file",
      "body": "Short, concrete review comment",
      "position": 123,
      "anchor": {
        "line_type": "addition",
        "left_line": 122,
        "right_line": 123,
        "hunk_index": 1,
        "line_index_in_hunk": 7,
        "hunk_header": "@@ -45,6 +45,12 @@",
        "prefixed_line": "+ actual changed line",
        "context_before": [
          " context line before"
        ],
        "context_after": [
          " context line after"
        ]
      }
    }
  ]
}
```

- Omit `discussion_fingerprint` when the review did not depend on
  discussion data. Do not require a separate preview hash or other
  hidden in-memory state to resume submission.
- `context_mode` controls submit-time recovery when local context is
  unavailable: `github-only` means no local files shaped the draft;
  `review-tree-optional` means local files were consulted but the
  visible draft can still be revalidated from GitHub artifacts alone;
  `review-tree-required` means the draft must be rebuilt from a clean
  `REVIEW_TREE` before it can be trusted again.
- The example above shows `position` only to document the finalized
  draft form. Omit `position` in the ordinary displayed draft artifact.
  During submit-time finalization, add exact GitHub `position` values
  back into each retained inline comment in that same artifact before
  submission.
- The finalized draft artifact is richer than the GitHub reviews API
  payload. When building the submission payload, keep only `event`,
  `commit_id`, `body`, and each retained comment's `path`, `position`,
  and `body`. Drop `draft_id`, `pr_repo`, `pr_number`,
  `base_ref_name`, `diff_fingerprint`, `discussion_fingerprint`, and
  each comment's `anchor` metadata from the payload.
- Treat `anchor` as hidden metadata for submit-time relocation. It does
  not need to be rendered in the user-visible draft preview, but every
  inline comment kept in the draft must retain enough anchor metadata to
  be re-positioned against the re-fetched patch later.
- Anchor field semantics are fixed:
  - `line_type` is one of `addition`, `deletion`, or `context`
  - `left_line` is the absolute pre-image file line number, or `null`
    when the anchored diff line has no left-side line
  - `right_line` is the absolute post-image file line number, or `null`
    when the anchored diff line has no right-side line
  - `hunk_index` is the zero-based hunk occurrence within that file in
    the normalized diff
  - `line_index_in_hunk` is the zero-based diff-line index within that
    hunk, excluding the hunk header
  - `prefixed_line` is the exact normalized diff line including its
    leading diff marker
  - `context_before` and `context_after` are small ordered lists of
    nearby normalized diff lines used only to disambiguate relocation
- Whenever a draft preview is rendered or refreshed, create the draft
  directory if needed and write or overwrite the per-PR draft artifact
  under `${TMPDIR:-/tmp}/codex-gh-pr-review/`. Generate a new `draft_id`
  whenever visible review content changes. Exception: the rendered
  `Draft ID: <draft_id>` line is metadata for the handoff and does not
  itself count as visible review content for draft rotation. Derive the
  new `draft_id` after the rest of the visible draft content is fixed,
  and do not rotate it again solely because that metadata line changed.
  During submit-time finalization, overwrite the same artifact in place
  with exact `position` values and any other hidden submit-ready fields;
  do not rotate `draft_id` for hidden field updates alone. If the
  artifact cannot be written, stop and tell the user
  `submit-to-github` cannot proceed until draft storage works.
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
- In ordinary review, do not suppress a finding just because a similar
  point may already exist on the PR. Before submission, only recompute
  exact GitHub diff positions for the approved inline comments. If
  anchor validation changes any visible review content, refresh the
  draft and ask for confirmation again.
- In `discussion-review` scope, do not promise complete thread state or
  full duplicate detection. Report each visible concern as `still
  applies`, `does not apply`, or `unclear from available GitHub data`.
- In `draft-only`, show the changed file path and a human line hint when
  helpful. Compute exact GitHub diff positions only when preparing a
  submission. If a file-specific point cannot be anchored reliably at
  submission time, move it into a `Promoted Findings` section in the
  final review body, refresh the draft, and ask for confirmation again
  instead of guessing.
- Keep the final review body synthetic, concise, and non-duplicative. It
  should state the overall shape of the findings in simple language, stay
  at 2 sentences or fewer unless the user asks for more, and never
  repeat, list, or point back to the inline comments. Exception: if
  approved inline comments are promoted because they cannot be anchored
  reliably, the refreshed draft may add a `Promoted Findings` section
  that enumerates only those migrated findings and may exceed the normal
  body limit.
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
- After the final review body, render `Draft ID: <draft_id>` on its own
  line.
- Render the latest user-visible draft. If submission finalization later
  changes any visible review content, show the refreshed draft before
  asking for confirmation again.

## Handle Common Variants

- Review a single PR: inspect GitHub metadata, diff, and targeted
  files. Ignore existing PR discussion unless the user explicitly asks
  for discussion review.
- Review existing PR comments: load the latest PR comments and reviews,
  treat visible discussion as best-effort input, and assess whether each
  concern `still applies`, `does not apply`, or is `unclear from
  available GitHub data` on the current head. Call out unresolved risk
  instead of drafting a second review that ignores the discussion
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
