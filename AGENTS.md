# AGENTS.md

Conventions for AI agents and contributors working in this repository. See
[`README.md`](README.md) for what the repo is and how its workflows are consumed.

## What this repo is

This is the `magicsunday` organization's `.github` repository. It holds two kinds
of files, with **org-wide blast radius**:

- **Community-health defaults** (`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `pull_request_template.md`, `.github/ISSUE_TEMPLATE/`) are inherited
  by every `magicsunday/*` repo that lacks its own. Editing one here changes the
  default for **all** repositories — review accordingly.
- **Reusable workflows** in `.github/workflows/` are called by sibling repos via
  `workflow_call`. A change on `main` reaches every consumer pinned to `@main` on its
  next run.
- `profile/README.md` renders the **public org profile** at `github.com/magicsunday`.

## Rules

- **4-space indentation in every YAML file.** No tabs, never 2 spaces. The `lint.yml`
  job dogfoods `yamllint.yml` against this repo's own workflows and will fail on drift.
  A naive 2→4 conversion breaks sequence items (`- ` is two chars; the body aligns to
  the dash *content*) — reindent by structure, then verify.
- **Reusable-workflow permission cap.** A called workflow's `GITHUB_TOKEN` is capped by
  the **caller's top-level `permissions:`**. A job-level grant inside the reusable
  workflow does not survive the move. When you add a scope a workflow needs, document
  it as a *caller* requirement in `README.md` — do not assume the job-level grant is
  enough.
- **Validate a workflow-file change before merge.** A reusable workflow cannot be
  exercised from a PR on this repo alone. Point one consumer caller at
  `@<branch>`, let its real CI run, confirm green, then flip back to `@main`.
- **Least privilege.** Every workflow declares the narrowest `permissions:` it needs.
  Do not widen a scope without a concrete reason.
- **No secrets passing.** The workflows run on the caller's `GITHUB_TOKEN`. Do not add
  `secrets:` inputs unless a workflow genuinely needs a non-default token.

## Commits

- Subject line: capitalized imperative verb, optionally prefixed `GH-<N>: ` for an
  issue-tied change. **No** conventional-commit prefixes (`feat:`/`fix:`/`chore:`),
  no lowercase or path-style starts.
- One concern per commit; keep style/lint fixes separate from content changes.
- **No** `Co-Authored-By:` trailer or other AI attribution.
- Commit only after the relevant lint/CI is green.
