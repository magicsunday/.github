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

The permission column is the **complete** block to put on the calling job — a
job-level block replaces the caller's top-level one instead of merging with it,
so an omitted scope is dropped to `none` and the run is rejected before any step
runs.

| Workflow | Purpose | Permissions the caller must grant |
| --- | --- | --- |
| `code-scanning.yml` | Semgrep scan, results uploaded as code-scanning alerts; fails when the scan does not complete | `contents: read`, `security-events: write` |
| `zizmor.yml` | Audit of the caller's workflow YAML (injection, permissions, pins) | `contents: read`, `security-events: write` |
| `scorecard.yml` | OSSF Scorecard supply-chain analysis (public repositories) | `security-events: write`, `id-token: write` |
| `dependency-review.yml` | Blocks vulnerable dependencies in a pull request | `contents: read`, `pull-requests: write` |
| `label-sync.yml` | Applies the canonical label set from `labels.yml` | `contents: read`, `issues: write` |
| `commit-convention.yml` | Enforces the commit-subject convention | `contents: read`, `pull-requests: read` |
| `yamllint.yml` | Lints YAML against the house style (4-space indent) | `contents: read` |
| `i18n.yml` | Enforces the catalogue layout; optional `make lang` freshness gate | `contents: read` |
| `bundle-freshness.yml` | Verifies committed build artefacts match a clean rebuild | `contents: read` |
| `greetings.yml` | Greets first-time contributors | `issues: write`, `pull-requests: write` |
| `auto-merge-deps.yml` | Auto-merges passing dependency bumps (patch and minor only; `pip` is excluded — see below) | `contents: write`, `pull-requests: write` |
| `ai-issue-labeler.yml` | Classifies a newly opened issue against the caller's own live label set via the Anthropic API and applies the labels it is confident about — see below | `issues: write` |
| `php-quality.yml` | Runs the granular `composer ci:test:php:*` PHP quality gate across a version matrix | `contents: read` |

`ai-issue-labeler.yml` also requires a `secrets: anthropic_api_key` passthrough, so every calling repository must provision its own `ANTHROPIC_API_KEY` secret. See the workflow's own header comment for why (no org-wide secret inheritance on this account) and the exact caller shape.

Two contracts are easy to miss when adopting `commit-convention.yml`: the caller
must include `edited` in its `pull_request` `types:`, or a corrected subject is
never re-checked; and the status context to require in branch protection is
`<calling-job-id> / Commit convention`, not `Commit convention`.

`auto-merge-deps.yml` skips the `pip` ecosystem **in this repository only**:
`.github/requirements/*.txt` hold the pinned tool versions the shared gates run,
so such a bump changes how a gate behaves in every repository, and a green run
here only proves the new version against this repository's own files. Those pull
requests stay open for a human. A consumer's own Python dependency is unaffected
and keeps auto-merging.

`code-scanning.yml` and `yamllint.yml` check this repository out a second time,
at the revision of the workflow being executed, to read the pinned tool
versions in `.github/requirements/`. `zizmor.yml` does the same second checkout
for a different reason: to compare the caller's `.github/zizmor.yml` against
the canonical copy in this repository, rather than to read a pinned tool
version.
That works with the caller's own `GITHUB_TOKEN` because this repository is
public, and it is the reason it has to stay public: making it private would red
`yamllint`, a required check in several repositories.

That second checkout lands at `.magicsunday-shared` and is deleted again once
the job no longer needs it - before the scan or the lint runs in
`code-scanning.yml`/`yamllint.yml`, and right after the comparison in
`zizmor.yml`, which reads the canonical copy out of `.magicsunday-shared`
itself and so has to delete it after, not before. Either way,
**`.magicsunday-shared` is a reserved path in a calling repository**: all
three workflows stop with a message naming it rather than deleting a path of
that name, which would leave it out of the scan (or make the verification
pass vacuously) without anything appearing to be missing.

### Inputs

Workflows not listed here take no inputs.

| Workflow | Input | Default |
| --- | --- | --- |
| `code-scanning.yml` | `excludes` — newline-separated extra paths to keep out of the scan, one pattern per line (a pattern may itself contain a space). Every path declared here leaves the uploaded report, so code scanning retires whatever alerts it held: declare only files that are not source | *(none)* |
| `yamllint.yml` | `paths` — space-separated YAML paths to lint | `.github/workflows/` |
| `i18n.yml` | `lang-dir` — root directory holding the per-locale catalogues | `resources/lang` |
| | `check-pipeline` — run `make lang` and fail on a non-empty diff | `false` |
| | `node-image` — image whose gettext must match the local `make lang` | `node:24-alpine` |
| `bundle-freshness.yml` | `bundle-dir` — directory whose committed artefacts must match a rebuild | `resources/js` |
| | `node-image` — image whose Node/Rollup must match the local `make build` | `node:24-alpine` |
| `php-quality.yml` | `php-versions` — JSON array of PHP versions for the build matrix | `["8.3", "8.4", "8.5"]` |
| | `run-psr4` — run the strict PSR-4 autoload check | `false` |
| | `run-infection` — run mutation testing, on the `infection-php` leg only | `false` |
| | `infection-php` — the single PHP version leg that runs mutation testing | `8.4` |

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
