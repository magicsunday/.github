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
- **Validate a workflow-file change before merge.** A reusable workflow cannot be
  exercised from a PR on this repo alone. Point one consumer caller at
  `@<branch>`, let its real CI run, confirm green, then flip back to `@main`.
- **Least privilege.** Every workflow declares the narrowest `permissions:` it needs.
  Do not widen a scope without a concrete reason.
- **No secrets passing.** The workflows run on the caller's `GITHUB_TOKEN`. Do not add
  `secrets:` inputs unless a workflow genuinely needs a non-default token.

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
