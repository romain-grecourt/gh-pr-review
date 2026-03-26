# Helidon Review Rules

Helidon-specific checklist used only after `SKILL.md` selects Helidon mode.
Use the review workflow and writing rules from `SKILL.md`; this file only
adds Helidon-specific risk checks.

## Risk Areas To Check

- Public API shape, backward compatibility, and new exposed types.
- Builder and config parity, changed defaults, and config key semantics.
- Exception translation, validation, null handling, and error paths.
- Module wiring, `module-info.java`, service registration, and Maven
  scopes or dependency versions.
- Concurrency, retries, timeouts, cleanup, startup, and shutdown.
- Missing unit, functional, or integration coverage for changed
  behavior.

## Recognize Helidon Context

- Expect a large multi-module Maven reactor rooted at `pom.xml`.
- Common module roots include `common`, `config`, `http`, `webserver`,
  `webclient`, `security`, `microprofile`, and `integrations`.
- Production code is usually in `src/main/java`, tests in
  `src/test/java`, released Java modules also include `module-info.java`,
  and broader verification often lives in `tests/functional`,
  `tests/integration`, or feature-specific `*/tests` modules.

## API and Structure

- When the change spans modules, confirm both sides of the boundary agree
  on the new behavior.
- Treat any public class or public method as Helidon API unless the
  module is clearly test-only or internal.
- Flag accidental API expansion, checked exceptions in public APIs, and
  `null` in public APIs.
- Prefer builders over public constructors for configurable types. Check
  builder/config parity.
- Public and protected APIs are expected to have Javadoc. Released
  modules should also keep `module-info.java` up to date.
- Helidon favors flat package structure. A new nested package can be a
  design smell and may indicate a missing module split.
- Directory name, Maven artifact, and package naming should remain
  aligned.
- Released Java modules should define `module-info.java`.
- Provided services belong in `module-info.java`; source
  `META-INF/services` in released modules is usually wrong.
- If a dependency leaks through a public API, check whether
  `requires transitive` is needed in `module-info.java`.

## Config, Runtime, and Tests

- Anything supported by config should generally be achievable through the
  programmatic builder API, and vice versa, unless a documented
  exception applies.
- Config keys should use lower-case dashed names such as
  `token-endpoint-uri`.
- Review changes to defaults, optional behavior, required config, and
  validation carefully.
- Pay extra attention to concurrency, retries, timeouts, resource
  cleanup, and service startup or shutdown.
- Prefer JUnit 5 with Hamcrest `assertThat` assertions. JUnit assertions
  are generally reserved for `assertAll` and `assertThrows`.
- Keep unit tests next to the module they cover. Use broader test suites
  such as `tests/functional`, `tests/integration`, or feature-specific
  `*/tests` when the behavior crosses module boundaries.
- Flag behavior changes that lack focused tests for negative cases, edge
  cases, or compatibility behavior.

## Maven and Dependency Hygiene

- Third-party dependency and plugin versions should be managed
  centrally. Flag new hard-coded versions unless there is a clear,
  approved reason.
- Helidon module versions should be inherited; avoid explicit versions
  for sibling modules.
- User-facing Java modules should be represented in `bom/pom.xml`.
- Review `pom.xml` changes for missing `name`, incorrect scope, or
  reactor-hostile naming.
