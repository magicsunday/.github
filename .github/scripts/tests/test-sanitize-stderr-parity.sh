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

require_files_or_bail "sanitize_for_annotation / _sanitize_for_stderr parity drift-guard test" \
    "${ANNOTATION_SANITIZE_FILE}" "${FIND_TARGETS_FILE}"

# shellcheck source=../lib/annotation-sanitize.sh
source "${ANNOTATION_SANITIZE_FILE}"

python_sanitize() {
    # Loaded via importlib.util.spec_from_file_location, not a bare `import
    # find_workflow_call_targets` off a PYTHONPATH-prepended lib/ dir: the
    # latter puts that directory ahead of the stdlib on sys.path, so any
    # future file placed there with a stdlib-colliding name (e.g. a
    # glob.py) would silently shadow the real module the moment
    # find_workflow_call_targets.py's own `import glob` resolves against it
    # instead - live-verified. This mirrors how
    # test_find_workflow_call_targets.py already loads the same module.
    python3 -c '
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("find_workflow_call_targets", sys.argv[1])
assert spec is not None and spec.loader is not None
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

sys.stdout.write(m._sanitize_for_stderr(sys.argv[2]))
' "${FIND_TARGETS_FILE}" "$1"
}

assert_parity() {
    local description="$1" input="$2"
    local bash_out python_out
    bash_out="$(sanitize_for_annotation "${input}")"
    python_out="$(python_sanitize "${input}")"
    assert_eq "sanitize parity: ${description}" "${bash_out}" "${python_out}"
}

# A ground-truth anchor on top of the cross-language comparison below - a
# blind change identical on both sides (e.g. both implementations starting
# to strip a leading "sub") would otherwise leave two matching-but-wrong
# strings that assert_parity alone certifies as agreement, the same failure
# shape assert_nonempty already guards against elsewhere in this suite.
assert_eq "sanitize parity: plain text is unchanged (ground truth)" \
    "sub/real.yml" "$(sanitize_for_annotation "sub/real.yml")"

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

# Boundary fixtures - issue #80 was exactly a one-codepoint-range gap on one
# side only (tr's single-byte class missing the C1 block a UTF-8-aware jq
# gsub catches), and jq's [[:cntrl:]] (an external oniguruma-defined class)
# vs. Python's hand-typed regex range are two independent range definitions
# that could drift apart at exactly their edges without any interior
# fixture ever noticing.
assert_parity "DEL (0x7F) is folded" "$(printf 'sub\x7fdir.yml')"
assert_parity "a tilde (0x7E, just below DEL) survives unchanged" "sub~dir.yml"
assert_parity "the C1 range's lower boundary (U+0080) is folded" \
    "$(printf 'sub\xc2\x80dir.yml')"
assert_parity "the C1 range's upper boundary (U+009F) is folded" \
    "$(printf 'sub\xc2\x9fdir.yml')"
assert_parity "just past the C1 range (U+00A0 NBSP) survives unchanged" \
    "$(printf 'sub\xc2\xa0dir.yml')"

report_and_exit "sanitize_for_annotation / _sanitize_for_stderr parity drift-guard test"
