#!/usr/bin/env bash
# Sourced by the pipeline freshness job of i18n.yml and by
# .github/scripts/tests/test-i18n-freshness.sh, so the workflow and its test
# drive the same file rather than two copies that can drift apart.

# Succeeds when the staged changes of the working tree consist of gettext
# source reference lines (`#: src/File.php:LINE`) alone, and when nothing is
# staged. A reference shifts with every unrelated code change and is no
# translation, so a catalogue that differs only there is not stale. Any other
# staged change fails the check: an added, removed or changed entry, a new
# file, and a compiled catalogue that differs.
i18n_only_references_changed() {
    git diff --cached --quiet -I '^#:'
}
