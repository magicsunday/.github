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
- Before requesting review, run the project's own quality gate locally (see
  "Development setup" below for the default command, and the README for any
  override). For modules that build front-end assets, also run `make build`
  and commit the rebuilt bundle.
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

- See the repository's README for any module-specific setup (e.g. Docker build box, asset build via `make build`), or for a different toolchain entirely.

## 5. Agent contributions

If the repository defines explicit agent rules (e.g. `AGENTS.md`), do not duplicate or reinterpret them in PRs — those files take precedence. Any contribution prepared or modified by an LLM/agent must comply with them.

## 6. Translations

webtrees modules ship their own catalogues in `resources/lang/<locale>/messages.po`.

- webtrees merges the compiled catalogue of a module over its own, so a filled entry for a text that webtrees core already translates replaces the core text in the whole installation, not only on the module's pages. Leave such entries empty so that core applies. Only translate texts that are specific to the module.
- The `i18n.yml` workflow fails a pull request that fills a text which core translates in that locale, and its annotation names the file, the line and the release of core that carries the text.
- Do not edit `messages.mo` or the `.pot` template by hand. Run `make lang`, which extracts the texts, merges the catalogues and compiles them.
- Source texts are written in American English like in core. British spellings belong in `en-GB`.
