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
<tr><td><code>label-sync.yml</code></td><td>Applies the canonical label set from <code>labels.yml</code></td><td><code>contents: read</code>, <code>issues: write</code></td></tr>
<tr><td><code>commit-convention.yml</code></td><td>Enforces the commit-subject convention</td><td><code>contents: read</code>, <code>pull-requests: read</code></td></tr>
<tr><td><code>yamllint.yml</code></td><td>Lints YAML against the house style (4-space indent)</td><td><code>contents: read</code></td></tr>
<tr><td><code>i18n.yml</code></td><td>Enforces the catalogue layout, with an optional <code>make lang</code> freshness gate and a core text overlap check</td><td><code>contents: read</code></td></tr>
<tr><td><code>bundle-freshness.yml</code></td><td>Verifies committed build artefacts match a clean rebuild</td><td><code>contents: read</code></td></tr>
<tr><td><code>ai-issue-labeler.yml</code></td><td>Classifies a newly opened issue via the Anthropic API against the caller's own live label set, leaves out the pull-request labels and the labels a maintainer sets, and applies the labels it is confident about (see below)</td><td><code>issues: write</code></td></tr>
<tr><td><code>php-quality.yml</code></td><td>Runs the granular <code>composer ci:test:php:*</code> PHP quality gate across a version matrix</td><td><code>contents: read</code></td></tr>
<tr><td><code>cpd.yml</code></td><td>Copy-paste detection with the caller's exact-pinned jscpd: <code>npm ci</code>, then the fixed jscpd command line; settings live in <code>.jscpd.json</code></td><td><code>contents: read</code></td></tr>
<tr><td><code>composer-audit.yml</code></td><td>Audits the Composer dependencies, the committed lock file when there is one and the freshly resolved set otherwise</td><td><code>contents: read</code></td></tr>
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

`code-scanning.yml` and `yamllint.yml` check this repository out a second time,
at the revision of the workflow being executed, to read the pinned tool
versions in `.github/requirements/`. `zizmor.yml` does the same second checkout
for a different reason: to compare the caller's `.github/zizmor.yml` against
the canonical copy in this repository, rather than to read a pinned tool
version. `commit-convention.yml` does it to source its subject predicate
(`.github/scripts/lib/commit-subject-predicate.sh`), self-test it against its
decision table, and source the shared annotation sanitizer
(`.github/scripts/lib/annotation-sanitize.sh`) its `::error::` lines route
through, `composer-audit.yml` to source its audit logic
(`.github/scripts/lib/composer-audit.sh`), and `ai-issue-labeler.yml` to stage its own
`ai-issue-labeler.sh`.
That works with the caller's own `GITHUB_TOKEN` because this repository is
public, and it is the reason it has to stay public: making it private would red
`yamllint`, a required check in several repositories.

That second checkout lands at `.magicsunday-shared`. `code-scanning.yml`,
`yamllint.yml`, `composer-audit.yml` and `zizmor.yml` also check the caller out, so they delete it
again once the job no longer needs it - before the scan, the lint or the audit runs in
the first three, and right after the comparison in `zizmor.yml`, which reads the
canonical copy out of `.magicsunday-shared` itself and so has to delete it
after, not before. For those four, **`.magicsunday-shared` is a reserved path
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
| `composer-audit.yml` | `php-version` — PHP version the audit runs with. The default is the first version of the `php-quality.yml` matrix | `8.3` |
| `i18n.yml` | `lang-dir` — root directory holding the per-locale catalogues | `resources/lang` |
| | `check-pipeline` — run `make lang` and fail on a non-empty diff | `false` |
| | `check-core-overlap` — fail when a catalogue entry translates a text that webtrees core already translates in that locale. An empty or fuzzy entry is fine, a compiled one replaces the core text in the whole installation. On a pull request the check runs when the pull request changes a file below `lang-dir`, the root `composer.json` or a workflow file | `true` |
| | `check-source-copies` — fail when a catalogue entry of any locale is a copy of its own source text. A singular entry is a copy when its translation equals the message id. A plural entry is a copy only when every form is filled and each one equals the message id or the plural message id. An empty entry is fine, the source text shows without it | `true` |
| | `core-tags` — space-separated webtrees release tags to compare with, empty derives them from the `fisharebest/webtrees` constraint of `composer.json` (`~`, `^` and exact forms) | *(none)* |
| | `node-image` — image whose gettext must match the local `make lang` | `ghcr.io/magicsunday/webtrees-docker-module-base:node24` |
| `bundle-freshness.yml` | `bundle-dir` — directory whose committed artefacts must match a rebuild | `resources/js` |
| | `node-image` — image whose Node/Rollup must match the local `make build` | `ghcr.io/magicsunday/webtrees-docker-module-base:node24` |
| `php-quality.yml` | `php-versions` — JSON array of PHP versions for the build matrix | `["8.3", "8.4", "8.5"]` |
| | `run-psr4` — run the strict PSR-4 autoload check | `false` |
| | `run-infection` — run mutation testing, on the `infection-php` leg only. On a pull request the mutation leg fetches the full history, whether or not the consumer defines the composer script `ci:test:php:infection:changed`. A pull request of a consumer that defines it is gated on the covered code of its changed lines. Every other run, and a consumer without that script, runs `ci:test:php:infection` over the whole tree. That run only reports once the consumer's own configuration has no fixed score floor | `false` |
| | `infection-php` — the single PHP version leg that runs mutation testing | `8.4` |

### Composer audit

`composer-audit.yml` audits the Composer dependencies of the calling repository
and fails on an advisory. The job is the same in every repository:

- Without a `composer.json` the job passes and says that there is nothing to audit.
- With a committed `composer.lock` it audits exactly that file. An empty, unreadable
  or symlinked lock file fails the job, so a broken lock file never turns into a
  quiet fresh resolution.
- Without a `composer.lock` it resolves the declared constraints fresh, as a consumer
  install does, and audits the result. Nothing is installed and no script or plugin
  of the repository runs.

The audit settings of the caller's `composer.json` apply exactly as they do for
Composer itself. An advisory ignored through `config.audit.ignore` or through
`config.policy.advisories.ignore-id` stays ignored, and the workflow has no ignore
handling of its own. A repository that already audits in its own CI, for example
through a Composer script that runs `composer audit`, runs the audit twice and may
drop its own step. The advisory policy of Composer also applies to the fresh
resolution, so a repository whose constraints resolve only to an advisory-flagged
version needs the ignore entries it needs for its own install.

The caller decides on which events the job runs. The canonical caller
(`templates/security.yml`) skips it on `pull_request` and runs it on `push`,
`schedule` and `workflow_dispatch`. This is a change for a repository whose inline
audit job ran on pull requests as well. The audit reads the advisory database of the
day, so on a pull request a newly published advisory against an existing dependency
would turn every open pull request red without any change in it. `dependency-review.yml`
covers what a pull request adds or changes.

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

Copy-paste detection, next to the PHP gate in a `CI` workflow:

```yaml
jobs:
    cpd:
        uses: magicsunday/.github/.github/workflows/cpd.yml@main
        permissions:
            contents: read
```

`cpd.yml` expects the jscpd install contract from
magicsunday/coding-standard#219: jscpd pinned to an exact version in
`package.json` `devDependencies` (jscpd 5.2.1 or newer), a committed
`package-lock.json`, and every scan setting (paths, ignores, threshold) in
`.jscpd.json`. It installs Node 24 and the locked tooling with `npm ci`, then runs
`node_modules/.bin/jscpd --config .jscpd.json --skip-comments --no-tips --fail-on-empty` —
no PHP and no Composer, and no npm in Composer hooks. A missing contract file
fails the job by name, and a scan that analyzes no file fails too. The exact pin
in `devDependencies` is what a dependency bot bumps.

## Security gate

`templates/security.yml` is the canonical `Security` caller. It sits outside
`.github/workflows/`, so it never runs in this repository, and a repository copies
it to its own `.github/workflows/security.yml`. This repository's own
`.github/workflows/security.yml` carries the same gate job next to its own jobs.

The job `all-security-checks`, named `All security checks`, is the one status check
that a branch protection requires. The set of security jobs differs per repository,
and a skipped job posts a different check than a run one, so listing each job as a
required check would be fragile.

- It depends on every other job of its file and runs whatever those jobs did
  (`if: ${{ always() }}`).
- It passes when each job succeeded or was skipped. It fails on `failure`,
  `cancelled`, any other result and a result document that is empty, malformed or
  has no job in it. A skipped job passes, which matters because `dependency-review`
  is skipped on every event but a pull request.
- It has no permissions (`permissions: {}`), checks nothing out and reads the
  results of the jobs from the environment, never from an interpolation into the
  script.
- Its name does not change with the event, so it can be required for pull requests
  and pushes alike.

The gate judges job results only. Whether a finding of a scanner fails that
scanner's job is a property of the shared workflow, and a repository that wants
findings to block a pull request needs a rule for that besides this check.

**The `needs` list must name every other job of the file.** A job that is not listed
cannot fail the gate. Add a job and its entry in the same change.
`.github/scripts/tests/test-security-gate.sh` checks that the list equals the other
jobs of both callers, runs the step against result documents of every kind and runs
in the shell tests of `lint.yml`.

### Variants of the caller

The callers of the repositories are the canonical file plus a few differences. A
difference is either a real parameter, which stays, or a gap, which the roll-out
aligns.

Real parameters, kept as inputs or guards:

- `excludes` of `code-scanning` and `paths` of `yamllint`, where a repository has
  large vendored documents or extra YAML.
- The guard `if: ${{ !github.event.repository.private }}` on the scanner jobs of a
  private repository. With every job skipped the gate passes.
- The self reference `$/` of this repository's own caller, documented in `AGENTS.md`.

Gaps, which the canonical file settles:

- The Composer audit is one job that calls `composer-audit.yml`, in every
  repository. It passes where there is no `composer.json`.
- One trigger branch list, `[main, master]`, and the `workflow_dispatch` trigger.
- The scorecard job publishes only for the default branch, and a manual run is
  allowed.
- The shared workflows are referenced as `@main`, the form that the zizmor policy of
  this repository (`.github/zizmor.yml`) sets for them.
- A `yamllint` job wherever the repository has YAML.

### Branch protection

Require the check `All security checks` next to the checks the repository requires
already. The gate is a job of the caller itself, so its status context is the job
name and has no `<caller job> / ` prefix (the reusable jobs report with that prefix).

- No pull-request review is required and no merge queue is used. The repositories
  have a single maintainer. A merge queue would need a `merge_group` trigger on the
  `Security` workflow, which the caller does not have.
- A repository whose security jobs are not green on the default branch yet gets an
  issue instead of a required check, since a required check that is red blocks every
  merge.
- Signed commits, the rules for administrators and the up-to-date requirement of the
  branch protection are decided in issue #292, not here.

## Labels

`labels.yml` is the single source of truth for the shared label set: the type
labels, the workflow labels such as `needs-triage` and `awaiting feedback`, the
`priority: *` levels, and the labels for dependency updates. Names are
lowercase. Keep those (`dependencies`, `github_actions` and the language
labels) lowercase in `labels.yml`.

The AI issue labeler reads each label as `name: description` and chooses from
that text, so a description there is a decision criterion and not a caption.
State what an issue must look like to deserve the label. A description that
opens with "Pull requests that" hides the label from the labeler, which is how
the pull-request-only labels stay out of its choices. One that opens with "Set
by maintainers" is hidden as well, for a decision or a workflow state that only
a maintainer can establish after reading the issue. A marker takes effect in a
repository once the sync has written the description there, and until then the
descriptions that repository had before apply.

The sync runs with `skip-delete`, so it only creates and updates: labels
specific to a repository are never removed. To change the set for every
repository, edit `labels.yml` here — each repository picks it up on its next
scheduled run.

## Canonical files

Some files must be byte-identical in every repository that needs them —
`.github/zizmor.yml` today, which tells zizmor that first-party reusable
workflows track `@main` by policy. `.github/canonical-files.json` lists them,
and this repository's own copy at the same path is the canonical content.

`canonical-drift.yml` checks every non-archived, non-fork repository of the
account once a week (and on demand via *Run workflow*) and fails, with a table
in the job summary, when a listed file is missing or differs. It only reports.
Fix a drifted repository by copying the file from here. Each manifest entry
can narrow its scope with `applies_when_present` (a path the repository must
have for the file to matter, `.github/workflows` for `zizmor.yml`). It runs on
this repository's own token, so it sees public repositories only.

The manifest has a second list, `template_sets`, for files whose canonical
content lives in another repository. A set names the source repository and
directory, the paths to leave out, the parameter file of a module and the
repositories that must carry the files. The sweep reads the directory from the
default branch of the source, so there is no copy of it here, and compares every
file of it, except the excluded ones, with the same path in each named
repository. That is the file set that the sync script of the template copies.
The identity lines of a PHP file (the package name and the namespace) belong to
the module, so the sweep renders them from `MODULE_NAME` and `MODULE_NS` in the
module's `Make/module.mk` before it compares, the same way the sync script does.
A module-local file that the template does not have is never looked at. The
report names the module and the file. A template file that a module lacks, one
with other content and a module without a usable `Make/module.mk` fail the run
like any other drift, and a template that cannot be read leaves its modules
unchecked. The comparison is by blob hash, so a changed file mode is not seen. The sync
script writes every file with the same non-executable mode, so the mode carries
no state of its own that the sweep would need to report.

## Contributing to this repository

`CONTRIBUTING.md` above stays generic since it is also served as the default
for repositories without their own — this repository itself has no
PHP/Composer toolchain. See its own workflows under `.github/workflows/` for
its actual CI configuration.
