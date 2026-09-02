# AGENTS.md

Conventions for AI agents and contributors working in this repository — the
`magicsunday` account's shared community-health files and reusable CI workflows.

## What this repo is

This is the `magicsunday` account's `.github` repository. It holds two kinds
of files, with **account-wide blast radius**:

- **Community-health defaults** (`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `pull_request_template.md`, `.github/ISSUE_TEMPLATE/`) are inherited
  by every `magicsunday/*` repo that lacks its own. Editing one here changes the
  default for **all** repositories — review accordingly.
- **Reusable workflows** in `.github/workflows/` are called by sibling repos via
  `workflow_call`. A change on `main` reaches every consumer pinned to `@main` on its
  next run.
The public profile page at `github.com/magicsunday` is **not** rendered from here —
`magicsunday` is a user account, so its profile lives in the separate
`magicsunday/magicsunday` repository's root `README.md` (an org account would use
`profile/README.md` here instead).

## Rules

- **4-space indentation in every YAML file.** No tabs, never 2 spaces. The `lint.yml`
  job dogfoods `yamllint.yml` against this repo's own workflows and will fail on drift.
  A naive 2→4 conversion breaks sequence items (`- ` is two chars; the body aligns to
  the dash *content*) — reindent by structure, then verify.
- **Reusable-workflow permission cap.** A called workflow's `GITHUB_TOKEN` is capped by
  the **calling job's `permissions:`** when it declares one — a job-level block
  replaces the caller's top-level block rather than merging with it — otherwise the
  caller's top-level block, otherwise the repository default. A job-level grant inside the reusable
  workflow does not survive the move. When you add a scope a workflow needs, note it as
  a *caller* requirement in that workflow's own header comment (as the existing
  workflows do) — do not assume the job-level grant is enough.
- **Pin every tool a workflow installs, in `.github/requirements/`.** An unpinned
  install re-resolves on every run, so a new upstream release changes the behaviour of
  a gate across the whole account with nothing here having changed — and `yamllint` is
  a required check. Dependabot tracks these files through its `pip` ecosystem; an
  inline `pip install <tool>` in a `run:` block is invisible to it, pinned or not.
  What makes a file here discoverable is worth knowing before editing one: the
  `pip` fetcher takes every `*.txt` / `*.in` in the configured directory and keeps
  it if the name contains `requirements` **or** every line parses as a requirement
  — blank lines and lines opening with `#`, `-r `, `-c `, `-e ` or `--` count as
  parsing. Every hash-locked `.txt` here qualifies on the second arm by
  construction — `pip-compile`'s own output is nothing but comment lines and
  parseable requirement lines — so free prose added to one would drop it from
  the updater silently.
  These bumps are excluded from auto-merge — see `auto-merge-deps.yml`. (The rule is
  about what a workflow installs *itself*: a SHA-pinned action that brings its own
  binary, as `zizmor.yml` does, already has its version tracked by the
  `github-actions` ecosystem.)
- **Each `.txt` here is a hash-locked closure, compiled from the matching `.in`.**
  Pinning only the direct requirement (the version line in `semgrep.in`) still
  lets `pip install -r` re-resolve every transitive dependency live on each
  run — the direct pin
  stops an upstream release from changing the tool version, but not from changing
  what it depends on. Bump the version in the `.in` file, then regenerate matching
  the runner these tools actually install on
  (`grep -h "python-version:\|runs-on:" .github/workflows/code-scanning.yml
  .github/workflows/yamllint.yml`; both currently `'3.12'` on `ubuntu-latest`, i.e.
  linux/amd64) — pin the container platform explicitly, or a Docker host on a
  different architecture (e.g. Apple Silicon) resolves different wheels/hashes
  than the runner installs and `--only-binary=:all:` then fails the install rather
  than silently degrading:
  `docker run --rm --platform linux/amd64 -v "$PWD/.github/requirements:/work" -w /work python:3.12 bash -c "pip install pip-tools==7.6.1 && pip-compile --allow-unsafe --generate-hashes --output-file=<name>.txt <name>.in"`
  (run from the repo root — the mount source is relative to the caller's `$PWD`).
  Pinning the `pip-tools` version too avoids tool-version-driven hash churn
  between two regenerations of the same `.in`, so a genuine dependency change
  doesn't hide inside noise from an unrelated `pip-tools` bump — it does not by
  itself guarantee byte-identical output across time, since pip-compile still
  resolves transitive versions against whatever the live index currently serves.
  Verify the result installs before committing, in the same container so the
  platform and Python version actually match what CI installs against (run
  from the repo root, same as the regenerate command above):
  `docker run --rm --platform linux/amd64 -v "$PWD/.github/requirements:/work" -w /work python:3.12 pip install --only-binary=:all: --require-hashes -r <name>.txt`.
  (pip-compile's
  own header may record `--no-index` even though this command hits the real
  index: `get_compile_command()` in `pip-tools` 7.6.1's `utils.py` omits an
  option from the reconstructed header only when `option.default == value`; for
  the plain `--no-index` flag, `option.default` is `click`'s internal
  `Sentinel.UNSET` marker while the resolved value is `False` when the flag is
  unset, so the two never compare equal and the flag is always re-emitted —
  confirmed against the currently-resolved `click` — **run the re-derivation
  command in a container with a genuinely fresh, unconstrained `pip install
  pip-tools==7.6.1` (`click>=8`, no upper bound, so it floats to whatever is
  current), never against a pre-installed or manually version-pinned `click`**:
  an older `click` (checked: 8.1.3, 8.4.2) resolves the same option's default
  to the plain bool `False` instead of `Sentinel.UNSET`, which looks like this
  claim is false but only means the test environment was stale, not that the
  claim is wrong for what actually installs today. Re-derive with
  `python3 -c "from piptools.scripts.compile import cli; print(next(o for o in cli.params if o.name == 'no_index').default)"`
  inside the pinned image — `Sentinel.UNSET` reproduces this, `False` means a
  newer `click` fixed it and the header claim above no longer holds; this is
  not evidence the committed file was produced by a different command.) Never
  hand-edit a `.txt` — the next compile overwrites
  it, and a hand-added line carries no hash. The install steps pass
  `--require-hashes` together with `--only-binary=:all:`, so a resolved package
  lacking a wheel for that platform, or a hash mismatch, fails the install rather
  than resolving to something unverified. `pip-tools.txt` is the same kind of
  hash-locked closure, compiled from `pip-tools.in` the same way — it exists so
  the `pip-tools` version the CI freshness check below installs itself comes from
  a pinned, Dependabot-tracked file rather than a bare inline `pip install`,
  which the "Pin every tool a workflow installs" rule above forbids. `lint.yml`'s
  `pip-closures-fresh` job installs `pip-tools` from that closure, checks every
  committed `.txt` has a matching `.in` (an orphan of either fails the job), then
  for every `.in` file present regenerates the matching `.txt`, stages it, and
  diffs the STAGED copy against the committed one (`git add` then
  `git diff --cached --exit-code`) — plain `git diff` is silent on an untracked
  path, so this also catches a new `.in` whose `.txt` was never committed at
  all, not only a stale one. It runs on every pull request and on every push to
  `main`/`master` (`lint.yml`'s own triggers), so a bumped `.in` with a
  forgotten regeneration no longer stays green. This relies on `pip-compile`
  treating an already-committed output file as its resolution baseline (no
  `--upgrade`), the same baseline-reuse behaviour — and the same caveat about
  it — described above.
- **A scan report is only uploaded once the report itself says it is complete.**
  Code scanning reads what an uploaded report omits as *fixed*, so a scan that
  quietly covered less than the tree retires real alerts, and an exit code does not
  carry that. `code-scanning.yml` sources `.github/scripts/lib/semgrep-report-check.sh`
  to check a skip inventory, and `lint.yml`'s `semgrep-smoke` job sources the same
  file for its `build_minified_fixture()` helper; its comments hold the mechanics
  and the commands that re-derive them. Two prohibitions before you edit it: do not
  drop the flags it calls load-bearing, and do not turn its allow list of tolerated
  skip reasons into a deny list — widen that list only for a reason meaning the
  file was never a scan target or its content cannot carry a finding any rule
  could make, and only against the
  engine's own definition. `minified` was carried as a tolerated exception to both
  grounds until issue #50 verified against the pinned engine that it cannot occur
  through this workflow's invocation — it is not on the list.
- **When a reusable workflow's `run:` block grows real logic (argument
  construction, report assertions — a bare exit-code check is usually too small to
  be worth this) worth pinning against regression, put it in `.github/scripts/lib/*.sh`,
  sourced by the workflow rather than duplicated into it,** with a matching
  `.github/scripts/tests/test-*.sh` that sources the SAME file. `lint.yml`'s
  `shell-tests` job runs every `test-*.sh` on push to main/master and on every pull
  request, so a regression in that logic fails CI before it reaches a caller — a
  workflow-only copy could drift silently, since nothing else re-checks a `run:`
  block. `code-scanning.yml` is migrated this way (`semgrep-excludes.sh`,
  `semgrep-report-check.sh`, `semgrepignore-guard.sh`, `annotation-sanitize.sh`,
  `retry.sh`, `semgrep-prune-dirs.sh`), as is
  `ai-issue-labeler.yml` (`ai-issue-labeler.sh` — request construction and
  response parsing); `yamllint.yml` and `i18n.yml` carry comparable inline
  `run:` logic that was deliberately left un-migrated when this convention was
  introduced (GH-47) — extending it to those is a separate decision, not something
  this bullet already claims is done.
- **The `p/*` Semgrep rule packs `code-scanning.yml` scans with cannot be pinned or
  vendored.** The Semgrep Rules License v. 1.0 forbids distributing the rules or
  making them available to others as a service, which a commit to this public,
  account-wide repository would be; and `semgrep scan --config` has no versioned or
  digest-addressed form of a registry entry — `p/<name>` is a mutable alias with no
  pinned variant (verified 2026-08-28 against `semgrep scan --help`'s `--config`
  section, and against the still-open upstream feature request for offline/cached
  rulesets; issue #44 has the full chain — re-check both before trusting this claim
  past that date). What the workflow does instead is retry the scan once, via
  `.github/scripts/lib/retry.sh`'s `run_with_retry()`, so a transient registry
  outage does not fail a run that a moment later would have succeeded — this
  narrows the failure window, it does not pin the policy. A renamed or removed rule
  pack is a permanent failure and simply fails the same way on the retry.
- **Read a reusable workflow's own files with the `job` context, never the `github`
  one.** A reusable workflow's `actions/checkout` fetches the **caller's** repository,
  so this repository's files are not in the workspace. Check them out separately with
  `repository: ${{ job.workflow_repository }}` and `ref: ${{ job.workflow_sha }}` —
  the revision of the workflow being executed, so a file always matches the workflow
  reading it — then remove that checkout before the job inspects the tree. Check
  first that the path is free: that removal is unconditional, so a caller that
  happens to keep a path of that name would have it dropped from the workspace,
  and with it from whatever the job goes on to lint or scan — without anything
  being reported as missing. Fail with a message naming the path instead.
  `github.job_workflow_sha` looks like the right property and is **not**: it exists
  only as an OIDC claim and interpolates to an empty string here, which
  `actions/checkout` silently treats as "default branch". Measured on both call
  shapes, remote and local `./`, on 2026-07-28. Because that failure is silent,
  assert both values are non-empty before using them. `job.workflow_*` is unavailable
  on GitHub Enterprise Server; irrelevant for this account, which is github.com-hosted.
  The checkout runs on the **caller's** `GITHUB_TOKEN`, so it resolves only while this
  repository is public — making it private would red `yamllint`, a required check in
  several repositories.
- **Validate a workflow-file change before merge.** A reusable workflow cannot be
  exercised from a PR on this repo alone. Point one consumer caller at
  `@<branch>`, let its real CI run, confirm green, then flip back to `@main`.
- **Least privilege.** Every workflow declares the narrowest `permissions:` it needs.
  Do not widen a scope without a concrete reason.
- **No secrets passing.** The workflows run on the caller's `GITHUB_TOKEN`. Do not add
  `secrets:` inputs unless a workflow genuinely needs a non-default token.
  `ai-issue-labeler.yml` is the one exception (re-derive: `grep -rl "^\s*secrets:"
  .github/workflows/` should return only that file): it calls the Anthropic API, which
  needs its own key, and this account has no org-wide secret inheritance to source it
  from — every consuming repository configures its own `ANTHROPIC_API_KEY` and passes
  it through explicitly (see that workflow's own header comment for the exact shape).
- **A `pull_request` run executes the PR's own code — that is the model, not a leak.**
  GitHub takes the workflow file itself from the PR's merge commit, and whatever the
  job then runs (a package manager's install/build scripts, the PR's own test suite)
  is the PR's code too. No gate declared inside a reusable workflow here binds a fork
  PR, because the PR controls the file the gate lives in — package-manager-level
  hardening (a resolver flag, a content check on a lockfile) is theatre once the PR can
  just delete the step that runs it. The one control that isn't PR-editable is the
  *consumer repository's* fork-PR-contributor-approval setting: re-derive with
  `gh api repos/<owner>/<repo>/actions/permissions/fork-pr-contributor-approval`.
  `all_external_contributors` requires owner approval for every external run;
  `first_time_contributors` (GitHub's default) only gates the first one — a returning
  contributor, or their later-compromised account, then runs unapproved.
- **Harden Runner.** `ai-issue-labeler.yml` is the first workflow in this account to
  add a `step-security/harden-runner` step, in `audit` (not `block`) mode — it is also
  the first to call an external service (the Anthropic API) while holding a repository
  secret, which is the shape Harden Runner exists to audit. Re-derive before trusting
  this: `grep -rl "harden-runner" .github/workflows/` should return only that file; the
  moment a second workflow adds one, this "no other reusable workflow here carries one"
  claim is stale and adding it elsewhere is a separate decision, not a convention this
  bullet already claims is universal.

## Commits

- Subject line: enforced by `.github/workflows/commit-convention.yml`, whose header
  holds the normative definition. A subject starting with `GH-` must match
  `^GH-\d+: <capital>`; every other subject must start with a capital. No
  conventional-commit prefixes and no path-like starts, whatever their case.
  `Merge …` / `Revert …` subjects git writes itself are exempt. The gate does NOT
  enforce that commits on a `GH-<N>` branch carry the prefix — it is keyed on the
  subject alone, so that the rule stays decidable for commits already on `main`,
  where the branch no longer exists.
  Do not restate the rule as "optionally prefixed `GH-<N>: `" — that folds the two
  branches into one optional group, which enforces nothing after the prefix,
  because the group can be skipped and the `G` of `GH-` then satisfies the capital
  on its own.
- One concern per commit; keep style/lint fixes separate from content changes.
- **No** `Co-Authored-By:` trailer or other AI attribution.
- Commit only after the relevant lint/CI is green.
