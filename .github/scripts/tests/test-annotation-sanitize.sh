#!/usr/bin/env bash
# Exercises sanitize_for_annotation() (.github/scripts/lib/annotation-sanitize.sh),
# the function code-scanning.yml's .semgrepignore guard and semgrep-report-check.sh
# both call before embedding caller-controlled text into a `::error::` workflow
# annotation - see that function's own comment for why both a raw control byte
# AND a percent-encoded one (`%0D`, `%0A`) have to be neutralised, and why a
# literal `?` in the path must survive intact. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/annotation-sanitize.sh
source "${SCRIPT_DIR}/../lib/annotation-sanitize.sh"

assert_eq "sanitize_for_annotation: plain text is unchanged" \
    "sub/.semgrepignore" "$(sanitize_for_annotation "sub/.semgrepignore")"
assert_eq "sanitize_for_annotation: newline-joined paths become space-joined" \
    "a/.semgrepignore b/.semgrepignore" \
    "$(sanitize_for_annotation "$(printf 'a/.semgrepignore\nb/.semgrepignore')")"
assert_eq "sanitize_for_annotation: embedded carriage return is neutralised" \
    "evil dir/.semgrepignore" \
    "$(sanitize_for_annotation "$(printf 'evil\rdir/.semgrepignore')")"
assert_eq "sanitize_for_annotation: embedded tab is neutralised" \
    "evil dir/.semgrepignore" \
    "$(sanitize_for_annotation "$(printf 'evil\tdir/.semgrepignore')")"
assert_eq "sanitize_for_annotation: a literal question mark survives intact" \
    "sub?dir/.semgrepignore" "$(sanitize_for_annotation "sub?dir/.semgrepignore")"
assert_eq "sanitize_for_annotation: percent-encoded CRLF is escaped, not decoded by the runner" \
    "evil%250D%250A::error::forged/.semgrepignore" \
    "$(sanitize_for_annotation "evil%0D%0A::error::forged/.semgrepignore")"

# The exact collision this function used to produce before GH-48 fixed it
# here - a control byte AND a literal `?` both folding to the same
# placeholder character - and semgrep-report-check.sh's jq_error path
# carried right up until issue #78 pointed it at this shared function
# instead. A control byte next to a literal `?` has to come out as two
# DISTINCT characters, or a reader cannot tell which one was originally
# control data.
assert_eq "sanitize_for_annotation: a literal question mark next to a folded control byte stays distinguishable" \
    "sub? dir/.semgrepignore" \
    "$(sanitize_for_annotation "$(printf 'sub?\x01dir/.semgrepignore')")"

report_and_exit "annotation-sanitize tests"
