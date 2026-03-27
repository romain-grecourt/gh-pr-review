# gh-pr-review

Codex skill for reviewing GitHub pull requests reachable through `gh`.

It is designed for static review only: focus on bugs, regressions, risky
assumptions, and missing focused tests. Reviews are persisted as JSON under
`~/.codex/skills/gh-pr-review/.reviews`.

## Install

Clone the skill into the Codex skills directory:

```bash
mkdir -p ~/.codex/skills
git clone git@github.com:romain-grecourt/gh-pr-review.git ~/.codex/skills/gh-pr-review
```

Codex discovers the skill from the `SKILL.md` file in that directory.

To update an existing install:

```bash
git -C ~/.codex/skills/gh-pr-review pull --ff-only
```

## Prerequisites

- `git`
- `bash`
- `jq`
- GitHub CLI (`gh`)
- `shasum` or `sha256sum`
- An authenticated GitHub CLI session for live PR access:

```bash
gh auth login
```

## Basic Usage

From Codex, invoke the skill explicitly:

```text
Use $gh-pr-review to review PR 123 in owner/repo.
```

The expected flow is:

1. Resolve the repo and PR number.
2. Fetch PR metadata and the exact patch with `gh`.
3. Draft a complete review JSON document locally.
4. Save it with `./scripts/gh-pr-review.sh save`.
5. Preview it with `./scripts/gh-pr-review.sh preview`.
6. Edit or submit it after the preview is shown.

The helper script exposes the public interface below:

```bash
./scripts/gh-pr-review.sh ls [--repo OWNER/REPO] [--pr NUMBER]
./scripts/gh-pr-review.sh save --input FILE [--review-file FILE]
./scripts/gh-pr-review.sh preview --review-file FILE
./scripts/gh-pr-review.sh submit --review-file FILE
./scripts/gh-pr-review.sh help
```

Useful examples:

```bash
./scripts/gh-pr-review.sh ls --repo owner/repo --pr 123
./scripts/gh-pr-review.sh preview --review-file ~/.codex/skills/gh-pr-review/.reviews/owner/repo/pr-123/review-001.json
./scripts/gh-pr-review.sh submit --review-file ~/.codex/skills/gh-pr-review/.reviews/owner/repo/pr-123/review-001.json
```

## Notes

- `preview` can show live diff hunks when GitHub state still matches the saved
  review.
- When used from Codex, `preview` and `submit` should run with escalated
  execution because they may access live GitHub state.
- `submit` validates the saved `head_sha` and `diff_fingerprint` before posting
  the review to GitHub.
- Do not store extra long-lived review artifacts under this skill directory;
  use `/tmp` for temporary working files when needed.
