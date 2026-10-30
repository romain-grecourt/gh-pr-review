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

Manage persisted review attempts with `./scripts/gh-pr-review.sh`:

- `gh-pr-review.sh ls [--repo OWNER/REPO] [--pr NUMBER]`
- `gh-pr-review.sh save --input FILE [--review-file FILE]`
- `gh-pr-review.sh preview --review-file FILE`
- `gh-pr-review.sh submit --review-file FILE`
- `gh-pr-review.sh reconcile --review-file FILE`
  `[--github-review-id ID]`
- `gh-pr-review.sh help`

Storage is fixed at `~/.codex/skills/gh-pr-review/.reviews`. Do not persist
PR metadata, patches, changed-file lists, payloads, session manifests, or
other long-lived artifacts alongside the skill. Temporary files outside the
skill directory are fine.

`preview` may render any valid review JSON path. `save`, `ls`, `submit`, and
`reconcile` remain bound to the canonical `.reviews` store.

Always request escalated execution for `preview`, `submit`, and `reconcile`.
They use live GitHub state. Do not first run them in the sandbox and retry
after a network failure.

`save` stores a complete review document. Do not assemble drafts through
incremental mutation commands. If the helper exits non-zero, show its output
and halt; do not improvise storage or submission flows.

## Review JSON V2

Create new drafts as Review JSON v2:

- `version`: `2`
- `repo`: normalized lowercase `owner/repo`
- `pr_number`: positive integer
- `base_sha`: exact 40-character PR base commit used during analysis
- `head_sha`: exact 40-character PR head commit used during analysis
- `event`: `COMMENT`, `APPROVE`, or `REQUEST_CHANGES`
- `body`: string; it may be empty or contain newlines
- `findings`: objects with `path`, `side`, `line`, and `body`
- `submission`: absent on drafts; the helper owns it after submission or
  verified reconciliation

Use `left` for a line on the base side and `right` for a line on the head
side. The helper submits native GitHub `path`, `line`, and uppercase `side`
anchors. Never store or calculate legacy diff `position` values.

V2 freshness uses `base_sha` and `head_sha`, checked again immediately before
submission. V2 does not contain or validate `diff_fingerprint`, so large pull
requests do not depend on `gh pr diff`.

## V1 Compatibility

Review JSON v1 files remain valid and must not be migrated or rewritten just
because the skill was updated. They can still be listed, previewed, edited,
submitted, and reconciled.

V1 uses `head_sha`, `diff_fingerprint`, and the same finding shape. Some v1
files contain `event`; older no-event files default to `COMMENT`. Its
fingerprint is the SHA-256 of the exact bytes from:

```bash
gh pr diff PR_NUMBER -R OWNER/REPO --patch --color=never
```

For the known GitHub `diff too_large` response on a public repository, the
helper validates the equivalent public PR `.patch` response. GitHub does not
provide a usable fallback for private large-PR v1 drafts; create a new v2
attempt with the current base and head SHAs when the helper reports that
condition.

## Flow

1. Resolve `OWNER/REPO` and `PR_NUMBER`.
2. Discover prior attempts with `gh-pr-review.sh ls` or by inspecting
   `.reviews`.
3. Update an existing unsubmitted attempt or create the next numbered file.
4. Obtain PR metadata, the complete changed-file set, patches, and any extra
   file context directly with read-only `gh` or `git` commands. Use the
   paginated pull-request-files API when `gh pr diff` cannot represent a
   large PR.
5. Record the exact live base and head SHAs and draft a complete v2 document
   in a temporary file.
6. Persist it with `save --input TEMP_FILE`, adding `--review-file` only when
   editing the selected draft.
7. Run `preview --review-file SAVED_FILE` with escalated execution.
8. Show preview stdout verbatim. Do not restyle, summarize, or reconstruct it.
   Then ask the user `edit or submit`.
9. Any edit invalidates prior approval. Save the full edited document and
   show a fresh preview.
10. Run `submit` only after explicit approval of the currently displayed
    preview.
11. If freshness validation fails, leave the draft untouched and create the
    next attempt from current PR state.
12. Never reuse a submitted review file for new content.

Preview validation is explicit:

- `live validation`: saved PR state and available finding context match.
- `stale validation`: the saved commit state no longer matches GitHub.
- `partial validation`: freshness or some finding context could not be fully
  checked.
- `offline validation`: live GitHub state is unavailable.
- `missing patch`: GitHub omitted patch context for that finding.

The preview can still show context from each pull-request file whose `patch`
field is present. Treat stale, partial, offline, and missing-patch labels as
real limitations; do not imply that the finding was fully validated.

## Reconciliation

Use `reconcile` only to record a review that GitHub already accepted while
the saved file still lacks `submission`, such as after a manual submission or
an uncertain client result. It never submits a review.

The helper checks the authenticated user, repository, PR, saved head SHA,
event state, normalized body, and every finding path and body. It writes
submission metadata only when exactly one GitHub review matches. If multiple
reviews match, inspect them and retry with the exact `--github-review-id`.

## Review Rules

- Prioritize bugs, regressions, risky assumptions, compatibility issues,
  hidden failures, and missing focused tests.
- Use static analysis only. Aside from read-only `gh` and `git` commands for
  PR context, do not run reviewed code or project commands, including tests,
  builds, linters, formatters, package-manager tasks, or runtime probes.
- Keep findings concrete, anchored, and high-value. Skip style-only remarks
  unless they hide a real defect.
- Use `findings` for points anchored to the diff and `body` for the concise
  overall state or points that cannot be anchored exactly.
- Do not use first person. Say `this PR` or `this changeset`.
- If no findings remain, say so explicitly and note residual risk.

Read extra references only when they apply:

- `references/helidon-review.md` for Helidon repositories.
- `references/review-checklist.md` for public APIs, persistence, config,
  auth, concurrency, or build/test wiring.
