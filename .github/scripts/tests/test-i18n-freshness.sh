#!/usr/bin/env bash
# Exercises i18n_only_references_changed() (.github/scripts/lib/i18n-freshness.sh),
# the function the pipeline freshness job of i18n.yml sources to tell a catalogue
# that only has moved source references from a stale one. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/i18n-freshness.sh
source "${SCRIPT_DIR}/../lib/i18n-freshness.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT
original_dir="$(pwd)" || exit 1

# new_repo NAME
# Creates a repository under work_dir with one committed catalogue and enters
# it. Every case gets its own repository, so a staged change never leaks into
# the next case.
new_repo() {
    local repo="${work_dir}/$1"
    mkdir -p "${repo}/resources/lang/nl" || exit 1
    cd "${repo}" || exit 1
    git init --quiet . || exit 1
    git config user.email "test@example.invalid"
    git config user.name "Test"
    git config commit.gpgsign false
    # A mode change is staged explicitly in its case, so the filesystem the
    # test runs on cannot decide whether git sees it.
    git config core.fileMode false
    cat > resources/lang/nl/messages.po <<'PO'
#: src/Module.php:10
msgid "Open"
msgstr "Openen"

#: src/Module.php:20
msgid "Close"
msgstr "Sluiten"
PO
    printf 'compiled-one' > resources/lang/nl/messages.mo
    git add -A
    git commit --quiet -m "Add the catalogue" || exit 1
}

# decide_after
# Stages the working tree like the workflow does and prints the exit status
# of the function under test.
decide_after() {
    git add -A
    i18n_only_references_changed
    echo $?
}

new_repo moved-references
sed -i 's|src/Module.php:10|src/Module.php:12|; s|src/Module.php:20|src/Module.php:22|' resources/lang/nl/messages.po
assert_eq "moved references only: passes" "0" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo changed-translation
sed -i 's|Openen|Opent|' resources/lang/nl/messages.po
assert_eq "changed translation: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo moved-references-and-changed-translation
sed -i 's|src/Module.php:10|src/Module.php:12|; s|Openen|Opent|' resources/lang/nl/messages.po
assert_eq "moved reference plus changed translation: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo added-entry
printf '\n#: src/Module.php:30\nmsgid "Save"\nmsgstr ""\n' >> resources/lang/nl/messages.po
assert_eq "added entry: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo removed-entry
printf '#: src/Module.php:10\nmsgid "Open"\nmsgstr "Openen"\n' > resources/lang/nl/messages.po
assert_eq "removed entry: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo changed-compiled-catalogue
printf 'compiled-two' > resources/lang/nl/messages.mo
assert_eq "changed compiled catalogue: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo new-locale
mkdir -p resources/lang/de
printf '#: src/Module.php:10\nmsgid "Open"\nmsgstr ""\n' > resources/lang/de/messages.po
assert_eq "new locale: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo new-empty-file
mkdir -p resources/lang/de
: > resources/lang/de/messages.po
assert_eq "new empty file: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo new-file-of-references-only
mkdir -p resources/lang/de
printf '#: src/Module.php:10\n' > resources/lang/de/messages.po
assert_eq "new file made of references only: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo deleted-catalogue
git rm --quiet resources/lang/nl/messages.mo
assert_eq "deleted compiled catalogue: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo renamed-catalogue
git mv resources/lang/nl/messages.po resources/lang/nl/renamed.po
assert_eq "renamed catalogue: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo changed-mode
git update-index --chmod=+x resources/lang/nl/messages.po
assert_eq "changed file mode: fails" "1" "$(decide_after)"
cd "${original_dir}" || exit 1

new_repo no-change
assert_eq "no change: passes" "0" "$(decide_after)"
cd "${original_dir}" || exit 1

report_and_exit "i18n freshness tests"
