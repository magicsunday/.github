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
# A non-control multi-byte UTF-8 character (not in jq's [[:cntrl:]] class)
# must survive the jq-based fold unchanged - the rewrite from tr to jq
# (issue #80) targets control-codepoint handling specifically and must not
# start mangling ordinary non-ASCII path bytes as a side effect.
assert_eq "sanitize_for_annotation: a non-control multi-byte UTF-8 character survives unchanged" \
    "caf$(printf '\xc3\xa9')/pl$(printf '\xc3\xa4')tze.txt" \
    "$(sanitize_for_annotation "$(printf 'caf\xc3\xa9/pl\xc3\xa4tze.txt')")"
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

# A C1 control codepoint (here U+0085 NEL, UTF-8-encoded as the two bytes
# 0xC2 0x85) is invisible to `tr '[:cntrl:]'`, which only recognizes
# single-byte ASCII control codes - neither byte of the pair falls in that
# range on its own (issue #80). Re-derive directly:
#   printf 'a\xc2\x85b' | tr '[:cntrl:]' ' ' | od -An -tx1
#       # 61 c2 85 62 -- passes through untouched
assert_eq "sanitize_for_annotation: a UTF-8-encoded C1 control codepoint (NEL) is neutralised" \
    "sub dir/.semgrepignore" \
    "$(sanitize_for_annotation "$(printf 'sub\xc2\x85dir/.semgrepignore')")"

# A raw byte in the same numeric range that is NOT valid UTF-8 on its own
# (no continuation byte) is neutralised too, as a side effect of jq
# requiring valid UTF-8 input: it substitutes U+FFFD (the UTF-8 bytes
# 0xEF 0xBF 0xBD) for the invalid byte rather than passing it through
# unfolded or erroring - not a control codepoint either way, so it cannot
# be read back as a line break.
assert_eq "sanitize_for_annotation: a raw non-UTF-8 byte in the C1 control range is neutralised" \
    "$(printf 'sub\xef\xbf\xbddir/.semgrepignore')" \
    "$(sanitize_for_annotation "$(printf 'sub\x85dir/.semgrepignore')")"

# The fail-closed fallback sanitize_for_annotation() now degrades to
# internally when jq itself fails (issue #83), both the default fallback
# text and an explicit, caller-supplied one - the callers that used to guard
# every call with `2>/dev/null || safe="(placeholder)"` dropped that guard in
# the same change, so this behaviour has to be pinned here instead. Simulated
# by shadowing jq on PATH with one that always fails, since
# sanitize_for_annotation() takes no flag to force the failure branch itself
# - a real jq failure is the only way it is reached.
fake_jq_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${fake_jq_dir}"' EXIT
cat > "${fake_jq_dir}/jq" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
chmod +x "${fake_jq_dir}/jq"

assert_eq "sanitize_for_annotation: a jq failure degrades to the default fallback text" \
    "(unavailable)" \
    "$(PATH="${fake_jq_dir}:${PATH}" sanitize_for_annotation "sub/.semgrepignore")"
assert_eq "sanitize_for_annotation: a jq failure degrades to an explicit, caller-supplied fallback text" \
    "(diagnostic unavailable)" \
    "$(PATH="${fake_jq_dir}:${PATH}" sanitize_for_annotation "some diagnostic text" "(diagnostic unavailable)")"

report_and_exit "annotation-sanitize tests"
