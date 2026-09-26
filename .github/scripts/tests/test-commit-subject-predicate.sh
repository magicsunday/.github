#!/usr/bin/env bash
# Pins subject_is_valid() (.github/scripts/lib/commit-subject-predicate.sh)
# against a decision table. Run via run-tests.sh, and run again by
# commit-convention.yml on the consumer's runner, from the same checkout of
# this repository it sources the predicate from — one table, one code path,
# whichever side runs it (issue #107). Every counting loop asserts how much it
# actually inspected, because the failure mode the gate must not have is
# passing without having checked anything.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/commit-subject-predicate.sh
source "${SCRIPT_DIR}/../lib/commit-subject-predicate.sh"

# Lower bound on the decision table's size, and the ONLY thing that detects
# rows going missing — the per-row shape assertion can only judge rows it
# actually read. Raise it in lockstep when adding a case, or each new row buys
# back one row of undetectable truncation.
readonly MIN_CASES=25

# An LC_ALL that is already set — commit-convention.yml's job-level pin — is
# kept, so the table is judged under the locale the gate will actually run
# with. Only an unset one falls back to the pin's own value, so a local run
# needs no setup. That fallback is also why this script cannot notice the
# workflow's pin being DROPPED; commit-convention.yml asserts that itself
# before running this.
export LC_ALL="${LC_ALL:-C.UTF-8}"

# The umlaut rows below fail on a non-UTF-8 locale, which would look like a
# predicate bug. Name the real cause instead.
if ! locale_is_utf8 "${LC_ALL}"; then
    echo "::error::LC_ALL is \"${LC_ALL}\", not a UTF-8 locale (pin C.UTF-8)"
    exit 1
fi

cases=0

# The table pins what this GATE does. On the capital class alone the gate is
# deliberately wider than the convention (see the predicate's header) — that
# is why the two umlaut rows assert PASS, and they are what keeps the
# effective locale honest. Elsewhere the gate is the NARROWER of the two: the
# `|BLOCK` rows starting with a capital (a bad `GH-` shape, a
# conventional-commit type, a path) reject a subject the bare `^[A-Z]`
# convention would pass.
#
# No skip-guard on the row: a row that arrives empty is a mangled table, and
# the case counter below turns that into a failure rather than a silent
# omission.
while IFS='|' read -r subject expected; do
    cases=$((cases + 1))

    # A row that lost its verdict column would otherwise be compared against
    # an empty string and merely look like a mismatch, hiding the real cause.
    case "$expected" in
        PASS|BLOCK) ;;
        *)
            echo "::error::malformed table row: \"${subject}|${expected}\""
            failures=$((failures + 1))
            continue
            ;;
    esac

    if subject_is_valid "$subject"; then
        actual=PASS
    else
        actual=BLOCK
    fi

    if [ "$actual" != "$expected" ]; then
        echo "::error::self-test: \"${subject}\" gave ${actual}, expected ${expected}"
        failures=$((failures + 1))
    fi
done <<'TABLE'
GH-123: Fix it|PASS
GH-123: fix it|BLOCK
GH-123: Über die Regel|PASS
Fix it|PASS
fix it|BLOCK
GH-Actions cleanup|BLOCK
GH-: Fix it|BLOCK
feat: add thing|BLOCK
Feat: add thing|BLOCK
fix(scope): add thing|BLOCK
Feat!: add thing|BLOCK
Feat(api)!: add thing|BLOCK
src/Module.php: fix|BLOCK
Src/Module.php: fix|BLOCK
Src/Module.php:fix|BLOCK
GH-1: Fix a/b: thing|PASS
Merge pull request #216 from magicsunday/GH-77|PASS
Merge branch 'main' into GH-77|PASS
Revert "Center silhouette assets on canvas"|PASS
Revert "feat: add thing"|PASS
Bump foo from 1.0 to 1.1|PASS
Ändern der Regel|PASS
ändern der Regel|BLOCK
Release 3.7.1|PASS
 |BLOCK
TABLE

# The table cannot express the empty subject — a blank row is
# indistinguishable from a mangled one — so it is asserted here.
if subject_is_valid ""; then
    echo "::error::self-test: an empty subject must not be accepted"
    failures=$((failures + 1))
fi

if [ "$cases" -lt "${MIN_CASES}" ]; then
    echo "::error::self-test read ${cases} table rows, expected at least ${MIN_CASES} — the decision table did not survive the heredoc"
    exit 1
fi

if [ "$failures" -gt 0 ]; then
    echo "::error::the subject predicate disagrees with its decision table in ${failures} case(s)"
    exit 1
fi

echo "  ✔ predicate agrees with all ${cases} cases"

# locale_is_utf8() itself: the spellings a re-pin may legitimately use, and
# the ones the umlaut rows would fail under. After the table, so a failure
# here is not reported as the predicate disagreeing with it.
for locale in C.UTF-8 C.utf8 en_US.UTF-8 de_DE.utf8@euro; do
    if locale_is_utf8 "${locale}"; then actual=PASS; else actual=BLOCK; fi
    assert_eq "locale_is_utf8 accepts ${locale}" PASS "${actual}"
done
for locale in C POSIX "" en_US.ISO-8859-1 UTF-8; do
    if locale_is_utf8 "${locale}"; then actual=PASS; else actual=BLOCK; fi
    assert_eq "locale_is_utf8 rejects \"${locale}\"" BLOCK "${actual}"
done

report_and_exit "commit-subject predicate tests"
