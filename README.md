# gh-pr-review

Codex skill for static review of GitHub pull requests reachable through
GitHub CLI. It focuses on bugs, regressions, risky assumptions, and missing
focused tests. Saved review JSON lives under
`~/.codex/skills/gh-pr-review/.reviews`.

## Install

Clone the skill into the Codex skills directory:

```bash
mkdir -p ~/.codex/skills
git clone git@github.com:romain-grecourt/gh-pr-review.git \
  ~/.codex/skills/gh-pr-review
```

Codex discovers the skill through `SKILL.md`. Update an existing install with:

```bash
git -C ~/.codex/skills/gh-pr-review pull --ff-only
```

The ignored `.reviews` directory is not changed by Git updates.

## Prerequisites

- `bash`
- `git`
- `jq`
- GitHub CLI (`gh`), authenticated to GitHub.com
- `shasum` or `sha256sum` for legacy v1 validation
- `curl` only when a public large-PR v1 review needs the `.patch` fallback

Authenticate GitHub CLI when needed:

```bash
gh auth login
```

## Basic Usage

From Codex, invoke the skill explicitly:

```text
Use $gh-pr-review to review PR 123 in owner/repo.
```

The normal flow is:

1. Resolve the repository, PR number, base SHA, and head SHA.
2. Analyze the complete PR, using the paginated pull-request-files API for
   large changesets.
3. Draft a complete Review JSON v2 document.
4. Save it with `save` and render it with `preview`.
5. Edit and preview again, or submit only after the displayed preview is
   explicitly approved.

The helper interface is:

```bash
./scripts/gh-pr-review.sh ls [--repo OWNER/REPO] [--pr NUMBER]
./scripts/gh-pr-review.sh save --input FILE [--review-file FILE]
./scripts/gh-pr-review.sh preview --review-file FILE
./scripts/gh-pr-review.sh submit --review-file FILE
./scripts/gh-pr-review.sh reconcile --review-file FILE \
  [--github-review-id ID]
./scripts/gh-pr-review.sh help
```

Examples:

```bash
./scripts/gh-pr-review.sh ls --repo owner/repo --pr 123
review=~/.codex/skills/gh-pr-review/.reviews/owner/repo/pr-123/
review="${review}review-001.json"
./scripts/gh-pr-review.sh preview --review-file "$review"
./scripts/gh-pr-review.sh submit --review-file "$review"
```

## Review JSON V2

New reviews use this shape:

```json
{
  "version": 2,
  "repo": "owner/repo",
  "pr_number": 123,
  "base_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "event": "COMMENT",
  "body": "Overall review body.",
  "findings": [
    {
      "path": "src/example.js",
      "side": "right",
      "line": 42,
      "body": "Inline finding."
    }
  ]
}
```

`event` may be `COMMENT`, `APPROVE`, or `REQUEST_CHANGES`. Findings use native
GitHub anchors: `path`, `line`, and `side`. The helper uppercases `side` in the
submission payload and never calculates legacy `position` values.

V2 freshness compares the saved base and head SHAs with live GitHub state
immediately before submission. It does not call `gh pr diff`, so it works for
PRs larger than GitHub's GraphQL diff limit.

## Preview States

Preview context comes from the paginated pull-request-files API. The output
labels its validation state:

- `live validation` means saved state and available finding context match.
- `stale validation` means the saved commit state changed.
- `partial validation` means only part of freshness or context was available.
- `offline validation` means live GitHub validation was unavailable.
- `missing patch` marks a finding whose file response omitted patch context.

GitHub can omit or truncate per-file patches even when the file itself is
returned. The preview keeps the saved finding visible and labels that limit.

## Legacy V1 Reviews

Existing v1 files remain supported without migration. Listing, preview,
editing, submission, and reconciliation continue to work. Event-bearing v1
files keep their event, while older no-event files default to `COMMENT`. V1
validates the exact `gh pr diff --patch` bytes by SHA-256.

When GitHub returns the known `diff too_large` error for a public repository,
the helper uses the equivalent public PR `.patch` response byte-for-byte.
Private large-PR v1 drafts cannot be validated that way; create a new v2 draft
with current base and head SHAs.

## Reconciliation

`reconcile` records a review that already exists on GitHub while the saved
draft still lacks submission metadata. It verifies the authenticated user,
repository, PR, saved head, event state, normalized review body, and all
finding paths and bodies. It updates the file only for one verified match.

Use `--github-review-id` to disambiguate multiple otherwise identical reviews.
Reconciliation never posts a review.

## Tests

Run the self-contained fake-GitHub suite with:

```bash
bash tests/test-gh-pr-review.sh
```

The suite covers large PR pagination, native anchors, stale state, omitted
patches, v1 compatibility and fallback, reconciliation, and failure safety.
