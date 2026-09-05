#!/usr/bin/env bash
# Drift-guard between the two hand-maintained implementations of the same
# escape-then-fold algorithm: sanitize_for_annotation() (bash,
# annotation-sanitize.sh) and _sanitize_for_stderr() (python,
# find_workflow_call_targets.py). issue #91 closed this exact drift class for
# every same-language call site by extracting ONE shared bash constant
# (ANNOTATION_SANITIZE_JQ_FILTER, tracked by
# test-annotation-sanitize-jq-parity.sh) after three prior incidents (issues
# #78, #80, #49) - but a Python subprocess cannot import a bash readonly
# variable, so the Python copy is necessarily a second, independent
# transcription of the same algorithm rather than a fourth call site of the
# shared constant. A value-based comparison across a shared fixture list is
# the only drift guard available across that language boundary.
#
# Scoped to inputs both sides can meaningfully agree on: valid Unicode text.
# sanitize_for_annotation() additionally substitutes U+FFFD for a raw,
# non-UTF-8 byte as a side effect of jq's own UTF-8 requirement (see
# test-annotation-sanitize.sh) - _sanitize_for_stderr() never receives raw
# bytes at all (it operates on already-decoded Python str values), so that
# case has no meaningful counterpart here and is intentionally not fixtured.
#
# Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
ANNOTATION_SANITIZE_FILE="${REPO_ROOT}/.github/scripts/lib/annotation-sanitize.sh"
FIND_TARGETS_FILE="${REPO_ROOT}/.github/scripts/lib/find_workflow_call_targets.py"

require_file "${ANNOTATION_SANITIZE_FILE}"
require_file "${FIND_TARGETS_FILE}"
# failures=0 is set at lib/harness.sh's top level, sourced above.
# shellcheck disable=SC2154
if [ "${failures}" -gt 0 ]; then
    report_and_exit "sanitize_for_annotation / _sanitize_for_stderr parity drift-guard test"
fi

# shellcheck source=../lib/annotation-sanitize.sh
source "${ANNOTATION_SANITIZE_FILE}"

python_sanitize() {
    PYTHONPATH="${SCRIPT_DIR}/../lib" python3 -c '
import sys

sys.path.insert(0, sys.argv[1])
import find_workflow_call_targets as m

sys.stdout.write(m._sanitize_for_stderr(sys.argv[2]))
' "${SCRIPT_DIR}/../lib" "$1"
}

assert_parity() {
    local description="$1" input="$2"
    local bash_out python_out
    bash_out="$(sanitize_for_annotation "${input}")"
    python_out="$(python_sanitize "${input}")"
    assert_eq "sanitize parity: ${description}" "${bash_out}" "${python_out}"
}

assert_parity "plain text is unchanged" "sub/real.yml"
assert_parity "a literal percent is escaped" "100%done.yml"
assert_parity "embedded newline is folded to a space" "$(printf 'legit\nother.yml')"
assert_parity "embedded carriage return is folded to a space" "$(printf 'legit\rother.yml')"
assert_parity "embedded tab is folded to a space" "$(printf 'legit\tother.yml')"
assert_parity "percent-encoded CRLF is escaped, not decoded by the runner" \
    "%0D%0A::error::forged.yml"
assert_parity "a UTF-8-encoded C1 control codepoint (NEL) is neutralised" \
    "$(printf 'sub\xc2\x85dir.yml')"
assert_parity "a literal question mark next to a folded control byte stays distinguishable" \
    "$(printf 'sub?\x01dir.yml')"

report_and_exit "sanitize_for_annotation / _sanitize_for_stderr parity drift-guard test"
