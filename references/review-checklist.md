# Review Checklist

Checklist for risky behavior changes and broad diffs after `SKILL.md`
selects it. Use the workflow, command, and output rules from `SKILL.md`.

## Check Correctness First

- Verify changed conditions, loops, and state transitions.
- Verify default values, null handling, empty-input behavior, and error
  paths.
- Verify renamed fields, config keys, flags, or routes still match their
  callers and consumers.
- Verify partial refactors do not leave old call sites on incompatible
  behavior.

## Check Compatibility and Data Safety

- Verify public APIs, serialized fields, config keys, environment
  variables, database columns, and wire formats preserve backward
  compatibility unless the PR explicitly documents a breaking change.
- Verify migrations, defaults, and rollback behavior when stateful data
  or persistent storage changes.
- Verify deletes and renames also update tests, docs, and generated
  artifacts that still reference the old name.

## Check Security and Operational Risk

- Verify authz/authn checks remain in place after refactors.
- Verify input validation, escaping, secret handling, and logging do not
  leak sensitive values.
- Verify retries, timeouts, concurrency control, and cleanup behavior
  still hold under failure.
- Verify feature flags, rollout guards, and metrics still cover the new
  path.

## Check Validation Quality

- Verify behavior changes have targeted tests, not just snapshot churn.
- Verify tests cover negative cases, edge cases, and failure handling.
- Verify generated outputs changed because their source changed, not
  because the generated files were edited directly.
