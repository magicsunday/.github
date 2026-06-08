# `.github`

This repository serves two purposes for the [`magicsunday`](https://github.com/magicsunday)
organization:

1. **Default community-health files** — `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
   `SECURITY.md`, `pull_request_template.md`, and the issue templates under
   `.github/ISSUE_TEMPLATE/` are inherited by every `magicsunday/*` repository that
   does not ship its own. Editing them here changes the default for all repos at once.
2. **Reusable GitHub Actions workflows** — a single source of truth for CI gates
   (linting, i18n, bundle freshness, security scanning, dependency review,
   auto-merge) that the sibling repositories call via `workflow_call`.

The organization profile page (`github.com/magicsunday`) is rendered from
[`profile/README.md`](profile/README.md).

## Reusable workflows

All workflows live in `.github/workflows/` and are consumed with
`uses: magicsunday/.github/.github/workflows/<file>@main`.

> **Permission cap:** a called reusable workflow's `GITHUB_TOKEN` is capped by the
> **caller's top-level `permissions:`** — a job-level grant in the reusable workflow
> does *not* survive the move. The caller must therefore declare every scope the
> workflow needs at the top level (or via `permissions:` on the calling job).

| Workflow | Purpose | Caller must grant | Inputs |
| --- | --- | --- | --- |
| `lint.yml` | Local dogfood — runs `yamllint.yml` against this repo's own workflow YAML | — | *(not reusable)* |
| `yamllint.yml` | Lint YAML against the house style (4-space indent) | `contents: read` | `paths` (default `.github/workflows/`) |
| `zizmor.yml` | Static analysis of GitHub Actions workflows | `contents: read`, `security-events: write` | — |
| `scorecard.yml` | OpenSSF Scorecard supply-chain checks (public repos) | `security-events: write`, `id-token: write` | — |
| `code-scanning.yml` | Semgrep static analysis — PHP / JS / secrets (CodeQL has no PHP support) | `contents: read`, `security-events: write` | — |
| `dependency-review.yml` | Block vulnerable / disallowed dependency changes on PRs | `contents: read`, `pull-requests: write` | — |
| `bundle-freshness.yml` | Fail when a committed JS bundle drifts from a clean rebuild | `contents: read` | `bundle-dir` (default `resources/js`), `node-image` (default `node:lts-alpine`) |
| `i18n.yml` | Validate gettext catalogues; optionally re-run `make lang` and diff | `contents: read` | `lang-dir` (default `resources/lang`), `check-pipeline` (default `false`), `node-image` (default `node:lts-alpine`) |
| `greetings.yml` | Greet first-time issue / PR authors | `issues: write`, `pull-requests: write` | — |
| `auto-merge-deps.yml` | Auto-merge eligible Dependabot patch/minor bumps | `contents: write`, `pull-requests: write` | — |

None of the workflows require `secrets:` to be passed — they run on the caller's
`GITHUB_TOKEN`. Consumers that push to a protected branch or open PRs supply their
own elevated token in the caller.

On a **private** consumer, `code-scanning.yml` and `scorecard.yml` additionally need
`actions: read` — `github/codeql-action/upload-sarif` reads workflow-run metadata to
attach the results. Public repos do not.

### Example consumer wiring

```yaml
name: CI

on:
    push:
        branches: [main]
    pull_request:

permissions:
    contents: read

jobs:
    yamllint:
        uses: magicsunday/.github/.github/workflows/yamllint.yml@main
        permissions:
            contents: read

    bundle-freshness:
        uses: magicsunday/.github/.github/workflows/bundle-freshness.yml@main
        permissions:
            contents: read
        with:
            bundle-dir: resources/js

    code-scanning:
        uses: magicsunday/.github/.github/workflows/code-scanning.yml@main
        permissions:
            contents: read
            security-events: write
```

## Maintenance

- **Indentation is 4 spaces** in every YAML file — the `lint.yml` job enforces it
  against this repo's own workflows.
- A change to a reusable workflow lands on `main` and is picked up by every consumer
  pinned to `@main` on its next run. Validate a workflow-file change before merging by
  pointing one consumer at `@<branch>` and letting its real CI run, then flip back to
  `@main`.
- Agent-facing conventions live in [`AGENTS.md`](AGENTS.md).
