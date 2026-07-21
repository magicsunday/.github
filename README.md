# .github

Shared configuration for the repositories in this account: the default
community-health files and a catalogue of reusable GitHub Actions workflows.

Community-health files (`SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
the issue templates and the pull-request template) are served automatically for
any repository that does not define its own. The workflows below are opt-in —
a repository adopts one by calling it.

## Reusable workflows

Every workflow is called with the `@main` ref. **The calling job must grant the
permissions listed here**: a reusable workflow's token is capped by the caller's
ceiling, so a missing permission does not fail the lint — it fails at runtime.

| Workflow | Purpose | Permissions the caller must grant |
| --- | --- | --- |
| `code-scanning.yml` | Semgrep scan, results uploaded as code-scanning alerts | `security-events: write` |
| `zizmor.yml` | Audit of the caller's workflow YAML (injection, permissions, pins) | `security-events: write` |
| `scorecard.yml` | OSSF Scorecard supply-chain analysis (public repositories) | `security-events: write`, `id-token: write` |
| `dependency-review.yml` | Blocks vulnerable dependencies in a pull request | `pull-requests: write` |
| `label-sync.yml` | Applies the canonical label set from `labels.yml` | `issues: write` |
| `commit-convention.yml` | Enforces the commit-subject convention | — |
| `yamllint.yml` | Lints YAML against the house style (4-space indent) | — |
| `i18n.yml` | Verifies the gettext catalogues are complete and fresh | — |
| `bundle-freshness.yml` | Verifies committed build artefacts match a clean rebuild | — |
| `greetings.yml` | Greets first-time contributors | `issues: write`, `pull-requests: write` |
| `auto-merge-deps.yml` | Auto-merges passing dependency bumps | `contents: write`, `pull-requests: write` |

### Inputs

Workflows not listed here take no inputs.

| Workflow | Input | Default |
| --- | --- | --- |
| `yamllint.yml` | `paths` — space-separated YAML paths to lint | `.github/workflows/` |
| `i18n.yml` | `lang-dir` — root directory holding the per-locale catalogues | `resources/lang` |
| | `check-pipeline` — run `make lang` and fail on a non-empty diff | `false` |
| | `node-image` — image whose gettext must match the local `make lang` | `node:24-alpine` |
| `bundle-freshness.yml` | `bundle-dir` — directory whose committed artefacts must match a rebuild | `resources/js` |
| | `node-image` — image whose Node/Rollup must match the local `make build` | `node:24-alpine` |

### Adopting a workflow

Security scanners, in a `Security` workflow:

```yaml
jobs:
    code-scanning:
        uses: magicsunday/.github/.github/workflows/code-scanning.yml@main
        permissions:
            contents: read
            security-events: write

    zizmor:
        uses: magicsunday/.github/.github/workflows/zizmor.yml@main
        permissions:
            contents: read
            security-events: write
```

The label sync, in a `Labels` workflow:

```yaml
jobs:
    sync:
        uses: magicsunday/.github/.github/workflows/label-sync.yml@main
        permissions:
            contents: read
            issues: write
```

## Labels

`labels.yml` is the single source of truth for the shared label set — the type
labels, the four `priority: *` levels, and the two Dependabot-managed labels.
Names are lowercase; `dependencies` and `github_actions` must stay lowercase
because Dependabot recreates them that way.

The sync runs with `skip-delete`, so it only creates and updates: labels
specific to a repository are never removed. To change the set for every
repository, edit `labels.yml` here — each repository picks it up on its next
scheduled run.
