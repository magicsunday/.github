# Contributing

## 1. How to contribute

- Check existing issues first to avoid duplicate work.
- For larger changes, open an issue before starting implementation.
- Keep contributions focused and small enough for clear review.
- Add or update tests for behavior changes.

## 2. Issues

- Use the affected repository's GitHub Issues.
- A good issue includes:
  - clear problem statement
  - minimal reproduction input or steps
  - expected vs. actual behavior
  - environment details (PHP version, relevant context)
- If your issue is meant for agent execution, use the repository's agent issue template.

## 3. Pull requests

- Open a PR from a branch in your fork.
- Describe scope, motivation, and validation steps.
- Follow the repository's pull-request template if present.
- Before requesting review, run the mandatory checks locally:
  - `composer ci:test`
  - For modules that build front-end assets, also run `make build` and commit the rebuilt bundle.
  - **This repository (`magicsunday/.github`) has no PHP/Composer toolchain** — its
    own gate is `lint.yml` (yamllint, pip-closures-freshness, semgrep-smoke, and the
    shell test suite). Reproduce the shell tests locally with
    `bash .github/scripts/tests/run-tests.sh`; the other jobs run against this
    repository's own CI configuration and have no separate local invocation.
- Include tests for new behavior and regression tests for fixes.

## 4. Development setup (minimal)

- PHP: `^8.3`
- Install dependencies:

```bash
composer install
```

- Run the project quality gate:

```bash
composer ci:test
```

- See the repository's README for any module-specific setup (e.g. Docker build box, asset build via `make build`).
- This section describes the PHP/Composer module setup shared by most
  `magicsunday/*` repositories. `magicsunday/.github` itself has no PHP toolchain —
  see the repository-specific note under "Pull requests" above.

## 5. Agent contributions

If the repository defines explicit agent rules (e.g. `AGENTS.md`), do not duplicate or reinterpret them in PRs — those files take precedence. Any contribution prepared or modified by an LLM/agent must comply with them.
