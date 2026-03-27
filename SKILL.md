---
name: gh-pr-review
description: >-
  Review GitHub.com pull requests reachable through GitHub CLI for bugs,
  behavioral regressions, risky assumptions, and missing focused test
  coverage. Use when the user asks for a PR review or wants a saved review
  submitted to GitHub after explicit approval of the shown preview.
---

# GitHub PR Review

Use this skill for GitHub.com pull requests reachable through `gh`.

Focus on correctness, regressions, risky assumptions, and missing focused
tests. Ignore CI status and existing PR discussion. Use static review only.

## Driver

All persisted review attempts are managed by `./scripts/gh-pr-review.sh`.

Only these public commands exist:

- `gh-pr-review.sh ls [--repo OWNER/REPO] [--pr NUMBER]`
- `gh-pr-review.sh save --input FILE [--review-file FILE]`
- `gh-pr-review.sh preview --review-file FILE`
- `gh-pr-review.sh submit --review-file FILE`
- `gh-pr-review.sh help`

Storage is fixed at `~/.codex/skills/gh-pr-review/.reviews`. Do not persist
`pr.json`, `pr.patch`, `changed-files.txt`, session manifests, payload files,
draft files, or any other long-lived review artifacts under this skill
directory. Temporary files in `/tmp` are fine when needed.

`preview` may render any valid review JSON file path. When live GitHub state is
reachable, it may also show contextual diff hunks around findings. `save`,
`ls`, and `submit` remain bound to the canonical `.reviews` store.

`save` stores a complete review JSON document. Do not reintroduce or document
incremental mutation commands or script-owned draft assembly.

If the helper script exits non-zero, treat it as authoritative: show the script
output and halt. Do not improvise fallback storage or submission flows.

## Review JSON V1

Draft a complete review document with:

- `version`: `1`
- `repo`: normalized lowercase `owner/repo`
- `pr_number`: positive integer
- `head_sha`: exact 40-character PR head commit used during analysis
- `diff_fingerprint`: lowercase SHA-256 of the exact stdout bytes from
  `gh pr diff PR_NUMBER -R OWNER/REPO --patch --color=never`
- `body`: string, may be empty, may contain newlines
- `findings`: array of objects with `path`, `side`, `line`, and `body`
- `submission`: absent on drafts; the script writes it after a successful
  `submit`

Never store GitHub diff `position` in the public JSON. `submit` resolves diff
anchors from the live patch after validating `head_sha` and
`diff_fingerprint`.

## Flow

1. Resolve `OWNER/REPO` and `PR_NUMBER`.
2. Discover existing attempts with `gh-pr-review.sh ls` or by inspecting
   `.reviews` directly.
3. Choose a target attempt:
   - update an existing unsubmitted review file, or
   - create the next numbered review file.
4. Obtain PR metadata, diff, and any extra file context directly with `gh` and
   `git` as needed. You may use direct CLI access, an existing local clone, or
   a disposable clone or worktree. A matching local repo is not required.
5. Compute `head_sha` from live PR metadata.
6. Compute `diff_fingerprint` from the exact patch bytes used during analysis.
7. Build a complete review JSON v1 document in a temporary local file.
8. Persist it through the script:
   - new attempt: `gh-pr-review.sh save --input TEMP_FILE`
   - update an existing draft:
     `gh-pr-review.sh save --input TEMP_FILE --review-file EXISTING_FILE`
9. Capture the saved path printed by `save`.
10. Run `gh-pr-review.sh preview --review-file SAVED_FILE`.
11. Show the preview stdout verbatim. Do not restyle it, summarize it, or
    reconstruct the format. Then ask the user `edit or submit`.
12. Any edit invalidates prior approval.
13. If the user requests edits, update the JSON content, run `save` again, and
    then run `preview` again.
14. Run `submit` only after the user explicitly approves the currently
    displayed preview.
15. If `submit` reports stale `head_sha` or `diff_fingerprint`, leave that file
    untouched and create the next numbered attempt for the new PR state.
16. Never reuse a submitted review file for new content.

## Review Rules

- Prioritize bugs, regressions, risky assumptions, compatibility issues,
  hidden failures, and missing focused tests.
- Keep findings concrete, anchored, and high-value. Skip style-only remarks
  unless they hide a real defect.
- Use `findings` for points that can be anchored to the diff.
- Use `body` for the concise overall state and any point that cannot be
  anchored exactly.
- `body` may be multi-line, but keep it concise.
- Do not use first person. Say `this PR` or `this changeset`.
- If no findings remain, say that explicitly and note residual risk.

Read extra references only when they apply:

- `references/helidon-review.md` for Helidon repositories.
- `references/review-checklist.md` for public APIs, persistence, config,
  auth, concurrency, or build/test wiring.
