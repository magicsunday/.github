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
  parsing. `semgrep.txt` and `yamllint.txt` qualify on the second arm, so free
  prose in one of them would drop it from the updater silently.
  These bumps are excluded from auto-merge — see `auto-merge-deps.yml`. (The rule is
  about what a workflow installs *itself*: a SHA-pinned action that brings its own
  binary, as `zizmor.yml` does, already has its version tracked by the
  `github-actions` ecosystem.)
- **A scan report is only uploaded once the report itself says it is complete.**
  Code scanning reads what an uploaded report omits as *fixed*, so a scan that
  quietly covered less than the tree retires real alerts, and an exit code does not
  carry that. `code-scanning.yml` sources `.github/scripts/lib/semgrep-report-check.sh`
  to check a skip inventory; its comments hold the mechanics and the commands that
  re-derive them. Two prohibitions before you edit it: do not drop the flags it calls
  load-bearing, and do not turn its allow list of tolerated skip reasons into a deny
  list — widen that list only for a reason meaning the file was never a scan target
  or its content cannot carry a finding any rule could make, and only against the
  engine's own definition. `minified` is the one documented exception to both
  grounds, tolerated as an accepted risk (issue #50).
- **When a reusable workflow's `run:` block grows real logic (argument
  construction, report assertions — a bare exit-code check is usually too small to
  be worth this) worth pinning against regression, put it in `.github/scripts/lib/*.sh`,
  sourced by the workflow rather than duplicated into it,** with a matching
  `.github/scripts/tests/test-*.sh` that sources the SAME file. `lint.yml`'s
  `shell-tests` job runs every `test-*.sh` on push to main/master and on every pull
  request, so a regression in that logic fails CI before it reaches a caller — a
  workflow-only copy could drift silently, since nothing else re-checks a `run:`
  block. `code-scanning.yml` is migrated this way (`semgrep-excludes.sh`,
  `semgrep-report-check.sh`, `retry.sh`), as is `ai-issue-labeler.yml`
  (`ai-issue-labeler.sh` — request construction and response parsing);
  `yamllint.yml` and `i18n.yml` carry comparable inline
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
