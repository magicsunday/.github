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

<!-- workflow-catalog:start -->
<table>
<thead>
<tr><th>Workflow</th><th>Purpose</th><th>Permissions the caller must grant</th></tr>
</thead>
<tbody>
<tr><td><code>code-scanning.yml</code></td><td>Semgrep scan, results uploaded as code-scanning alerts; fails when the scan does not complete</td><td><code>contents: read</code>, <code>security-events: write</code></td></tr>
<tr><td><code>zizmor.yml</code></td><td>Audit of the caller's workflow YAML (injection, permissions, pins)</td><td><code>contents: read</code>, <code>security-events: write</code></td></tr>
<tr><td><code>scorecard.yml</code></td><td>OSSF Scorecard supply-chain analysis (public repositories)</td><td><code>security-events: write</code>, <code>id-token: write</code></td></tr>
<tr><td><code>dependency-review.yml</code></td><td>Blocks vulnerable dependencies in a pull request</td><td><code>contents: read</code>, <code>pull-requests: write</code></td></tr>
<tr><td><code>label-sync.yml</code></td><td>Applies the canonical label set from `labels.yml`</td><td><code>contents: read</code>, <code>issues: write</code></td></tr>
<tr><td><code>commit-convention.yml</code></td><td>Enforces the commit-subject convention</td><td><code>contents: read</code>, <code>pull-requests: read</code></td></tr>
<tr><td><code>yamllint.yml</code></td><td>Lints YAML against the house style (4-space indent)</td><td><code>contents: read</code></td></tr>
<tr><td><code>i18n.yml</code></td><td>Enforces the catalogue layout; optional `make lang` freshness gate</td><td><code>contents: read</code></td></tr>
<tr><td><code>bundle-freshness.yml</code></td><td>Verifies committed build artefacts match a clean rebuild</td><td><code>contents: read</code></td></tr>
<tr><td><code>auto-merge-deps.yml</code></td><td>Auto-merges passing dependency bumps (patch and minor only; `pip` is excluded — see below)</td><td><code>contents: write</code>, <code>pull-requests: write</code></td></tr>
<tr><td><code>ai-issue-labeler.yml</code></td><td>Classifies a newly opened issue against the caller's own live label set via the Anthropic API and applies the labels it is confident about — see below</td><td><code>issues: write</code></td></tr>
<tr><td><code>php-quality.yml</code></td><td>Runs the granular `composer ci:test:php:*` PHP quality gate across a version matrix</td><td><code>contents: read</code></td></tr>
</tbody>
</table>

<!-- workflow-catalog:end -->

This table is generated from `.github/workflow-catalog.json` - edit that
file, then run `python3 .github/scripts/lib/workflow_catalog.py --write
README.md .github/workflow-catalog.json` and commit the result. A CI check
fails the build if the two drift apart.

`ai-issue-labeler.yml` also requires a `secrets: anthropic_api_key` passthrough, so every calling repository must provision its own `ANTHROPIC_API_KEY` secret. See the workflow's own header comment for why and the exact caller shape.

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
version. `commit-convention.yml` does it to source the shared annotation
sanitizer (`.github/scripts/lib/annotation-sanitize.sh`) its `::error::` lines
route through, and `ai-issue-labeler.yml` to stage its own
`ai-issue-labeler.sh`.
That works with the caller's own `GITHUB_TOKEN` because this repository is
public, and it is the reason it has to stay public: making it private would red
`yamllint`, a required check in several repositories.

That second checkout lands at `.magicsunday-shared`. `code-scanning.yml`,
`yamllint.yml` and `zizmor.yml` also check the caller out, so they delete it
again once the job no longer needs it - before the scan or the lint runs in
the first two, and right after the comparison in `zizmor.yml`, which reads the
canonical copy out of `.magicsunday-shared` itself and so has to delete it
after, not before. For those three, **`.magicsunday-shared` is a reserved path
in a calling repository**: each stops with a message naming it rather than
deleting a path of that name, which would leave it out of the scan (or make
the verification pass vacuously) without anything appearing to be missing.
`ai-issue-labeler.yml` and `commit-convention.yml` never check out the caller,
so nothing can collide with that path there.

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
labels, the four `priority: *` levels, and the three Dependabot-managed labels.
Names are lowercase; keep `dependencies`, `github_actions` and `python`
lowercase in `labels.yml` — as observed on 2026-09-05 (`gh label list`), all
three were lowercase, matching Dependabot's own ecosystem-default labels.

The sync runs with `skip-delete`, so it only creates and updates: labels
specific to a repository are never removed. To change the set for every
repository, edit `labels.yml` here — each repository picks it up on its next
scheduled run.

## Contributing to this repository

`CONTRIBUTING.md` above stays generic since it is also served as the default
for repositories without their own — this repository itself has no
PHP/Composer toolchain. See its own workflows under `.github/workflows/` for
its actual CI configuration.
