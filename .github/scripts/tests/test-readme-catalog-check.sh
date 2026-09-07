#!/usr/bin/env bash
# Exercises find_workflow_call_targets() and assert_readme_catalog_complete()
# (.github/scripts/lib/readme-catalog-check.sh), the functions lint.yml's
# "readme-catalog-fresh" job sources to keep README.md's workflow catalog
# honest against the real *.yml/*.yaml files (issue #101). Since issue #118,
# find_workflow_call_targets() shells out to find_workflow_call_targets.py
# for the actual trigger-shape detection - test_find_workflow_call_targets.py
# (run via test-find-workflow-call-targets.sh) pins that script's own
# per-shape unit behaviour and its YAML-parse-error handling; this file's
# job is the end-to-end wiring: sanitisation, the temp-file NUL-safe
# capture, and assert_readme_catalog_complete()'s README-table matching in
# both directions (issue #101 forward, issue #116 reverse) on top of
# whatever the Python script reports. Run via run-tests.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
source "${SCRIPT_DIR}/lib/harness.sh"
# shellcheck source=../lib/readme-catalog-check.sh
source "${SCRIPT_DIR}/../lib/readme-catalog-check.sh"

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "${work_dir}"' EXIT

# --- find_workflow_call_targets() ---

workflows_dir="${work_dir}/workflows"
mkdir -p "${workflows_dir}"

cat > "${workflows_dir}/real.yml" <<'EOF'
name: Real
on:
    workflow_call:
jobs:
    x:
        runs-on: ubuntu-latest
EOF

# A comment mentioning the trigger string, at a DIFFERENT indentation than
# a real trigger key ever has - the exact shape a bare substring grep would
# wrongly count as a target.
cat > "${workflows_dir}/mentions-only.yml" <<'EOF'
name: Mentions only

# See AGENTS.md for why this workflow does NOT declare workflow_call: itself.
on:
    push:
jobs:
    x:
        runs-on: ubuntu-latest
EOF

assert_eq "find_workflow_call_targets: only the file with a real, correctly-indented trigger is returned" \
    "real.yml" \
    "$(find_workflow_call_targets "${workflows_dir}")"

# A job literally named `workflow_call` sits at the same 4-space indent a
# real trigger key does - a plain regex matching any 4-space-indented
# `workflow_call:` line, regardless of whether it sits inside the `on:`
# mapping, would misdetect this as a trigger.
cat > "${workflows_dir}/job-name-collision.yml" <<'EOF'
name: Job named workflow_call
on:
    push:
jobs:
    workflow_call:
        runs-on: ubuntu-latest
EOF

assert_eq "find_workflow_call_targets: a job literally named workflow_call is not misdetected as a trigger" \
    "0" "$(find_workflow_call_targets "${workflows_dir}" | grep -c 'job-name-collision.yml')"
rm -f "${workflows_dir}/job-name-collision.yml"

# A workflow file whose final line is the trigger itself, with no trailing
# newline - a bash `while read` implementation of this function would
# silently drop this line at EOF; find_workflow_call_targets.py's own
# `yaml.safe_load()` has no such edge case, but this pins that guarantee
# end-to-end through the bash wrapper.
printf 'name: No trailing newline\non:\n    workflow_call:' \
    > "${workflows_dir}/no-trailing-newline.yml"

assert_eq "find_workflow_call_targets: a trigger on the file's last line, with no trailing newline, is still found" \
    "no-trailing-newline.yml" \
    "$(find_workflow_call_targets "${workflows_dir}" | grep 'no-trailing-newline.yml')"
rm -f "${workflows_dir}/no-trailing-newline.yml"

# A column-0 comment line INSIDE the on: mapping - valid YAML (comments
# ignore surrounding indentation) - must not hide the real trigger key
# beneath it. A real YAML parser already gets this right by construction,
# unlike the old sed-range heuristic this replaced, but this pins it
# end-to-end.
cat > "${workflows_dir}/mid-block-comment.yml" <<'EOF'
name: Comment inside on-block
on:
    push:
# a top-level comment mid-block
    workflow_call:
jobs:
    x:
        runs-on: ubuntu-latest
EOF

assert_eq "find_workflow_call_targets: a column-0 comment inside the on: block does not hide a later trigger" \
    "mid-block-comment.yml" \
    "$(find_workflow_call_targets "${workflows_dir}" | grep 'mid-block-comment.yml')"
rm -f "${workflows_dir}/mid-block-comment.yml"

# `on:` followed by trailing whitespace or an inline comment is still a
# valid top-level trigger key - a byte-exact `on:` match would miss it.
cat > "${workflows_dir}/on-inline-comment.yml" <<'EOF'
name: Inline comment on the on-trigger line
on: # reusable workflow
    workflow_call:
jobs:
    x:
        runs-on: ubuntu-latest
EOF

assert_eq "find_workflow_call_targets: an inline comment on the on: line does not hide the trigger" \
    "on-inline-comment.yml" \
    "$(find_workflow_call_targets "${workflows_dir}" | grep 'on-inline-comment.yml')"
rm -f "${workflows_dir}/on-inline-comment.yml"

# `on:` followed by trailing whitespace and nothing else (no comment) is
# the same valid shape, exercised separately since it is not implied by
# the inline-comment case above (the comment group is optional).
printf 'name: Trailing whitespace on the on-trigger line\non:   \n    workflow_call:\njobs:\n    x:\n        runs-on: ubuntu-latest\n' \
    > "${workflows_dir}/on-trailing-whitespace.yml"

assert_eq "find_workflow_call_targets: trailing whitespace on the on: line does not hide the trigger" \
    "on-trailing-whitespace.yml" \
    "$(find_workflow_call_targets "${workflows_dir}" | grep 'on-trailing-whitespace.yml')"
rm -f "${workflows_dir}/on-trailing-whitespace.yml"

# GitHub Actions accepts a .yaml extension exactly as it accepts .yml - a
# glob matching only *.yml would leave a workflow_call target saved as
# .yaml silently invisible to the whole check, rather than flagged as
# undocumented.
cat > "${workflows_dir}/real-yaml-ext.yaml" <<'EOF'
name: Real, .yaml extension
on:
    workflow_call:
jobs:
    x:
        runs-on: ubuntu-latest
EOF

assert_contains "find_workflow_call_targets: a .yaml-extension file with a real trigger is not skipped" \
    "$(find_workflow_call_targets "${workflows_dir}")" "real-yaml-ext.yaml"
rm -f "${workflows_dir}/real-yaml-ext.yaml"

# The scalar trigger shorthand (`on: workflow_call`, no block/mapping at
# all) - one of the two gaps issue #101 accepted and issue #118 closes via
# a real YAML parse. The old sed/grep detector's opening pattern anchored on
# `on:` followed by nothing but optional whitespace/comment, so a value on
# the SAME line (`on: workflow_call`) never started the range at all.
cat > "${workflows_dir}/scalar-trigger.yml" <<'EOF'
name: Scalar trigger shorthand
on: workflow_call
jobs:
    x:
        runs-on: ubuntu-latest
EOF

assert_contains "find_workflow_call_targets: the scalar trigger shorthand (on: workflow_call) is detected" \
    "$(find_workflow_call_targets "${workflows_dir}")" "scalar-trigger.yml"
rm -f "${workflows_dir}/scalar-trigger.yml"

# The flow-sequence trigger shorthand (`on: [push, workflow_call]`) - the
# other of the two issue #101 gaps. Also proves a NON-matching sequence
# (no workflow_call member) is correctly excluded, using the same shape.
cat > "${workflows_dir}/flow-sequence-trigger.yml" <<'EOF'
name: Flow-sequence trigger shorthand
on: [push, workflow_call]
jobs:
    x:
        runs-on: ubuntu-latest
EOF
cat > "${workflows_dir}/flow-sequence-no-trigger.yml" <<'EOF'
name: Flow-sequence without the trigger
on: [push, pull_request]
jobs:
    x:
        runs-on: ubuntu-latest
EOF

assert_contains "find_workflow_call_targets: the flow-sequence trigger shorthand (on: [push, workflow_call]) is detected" \
    "$(find_workflow_call_targets "${workflows_dir}")" "flow-sequence-trigger.yml"
assert_eq "find_workflow_call_targets: a flow sequence without workflow_call as a member is not misdetected" \
    "0" "$(find_workflow_call_targets "${workflows_dir}" | grep -c 'flow-sequence-no-trigger.yml')"
rm -f "${workflows_dir}/flow-sequence-trigger.yml" "${workflows_dir}/flow-sequence-no-trigger.yml"

# A QUOTED `'on':` key - the old sed/grep detector's own documented
# byte-exact-match gap (its opening pattern anchors on the literal text
# `on:` at column 0, which a quoted key never starts with). A real YAML
# parser resolves this to the same trigger mapping either way; see
# find_workflow_call_targets.py's own _has_workflow_call_trigger() for why
# the quoted form parses as the plain string key "on" rather than
# PyYAML's usual boolean-True resolution of the bare, unquoted form.
cat > "${workflows_dir}/quoted-on-key.yml" <<'EOF'
name: Quoted on-trigger key
'on':
    workflow_call:
jobs:
    x:
        runs-on: ubuntu-latest
EOF

assert_contains "find_workflow_call_targets: a quoted 'on': key is detected, closing the old detector's own documented gap" \
    "$(find_workflow_call_targets "${workflows_dir}")" "quoted-on-key.yml"
rm -f "${workflows_dir}/quoted-on-key.yml"

# A malformed (unparsable) workflow file sitting alongside a real target
# must not block detection of that sibling - find_workflow_call_targets.py
# skips a YAML parse error per-file rather than aborting the whole scan,
# and find_workflow_call_targets() itself must not treat that script's
# still-zero exit status (the error is reported on stderr, not by failing
# the process) as a reason to return early either.
cat > "${workflows_dir}/malformed.yml" <<'EOF'
on: {workflow_call:
EOF

assert_contains "find_workflow_call_targets: a malformed sibling file does not hide a real target" \
    "$(find_workflow_call_targets "${workflows_dir}")" "real.yml"
assert_eq "find_workflow_call_targets: a malformed file itself is never reported as a target" \
    "0" "$(find_workflow_call_targets "${workflows_dir}" | grep -c 'malformed.yml')"
rm -f "${workflows_dir}/malformed.yml"

# A percent-encoded CRLF (`%0D%0A`) in a filename is a forgery channel
# SEPARATE from a raw control byte - see annotation-sanitize.sh's own
# header for why both need neutralising and why a plain `tr -d '\r\n'`
# cannot see this one at all. Pins that find_workflow_call_targets()
# actually routes through sanitize_for_annotation() rather than a
# narrower, hand-rolled guard.
cat > "${workflows_dir}/%0D%0A::add-mask::pwned.yml" <<'EOF'
on:
    workflow_call:
EOF
# Structural wiring check, not a re-pin of sanitize_for_annotation()'s exact
# escape format - that byte-exact guarantee already lives at its one source,
# test-annotation-sanitize.sh; two exact-value pins of the same fact would
# only drift independently.
assert_contains "find_workflow_call_targets: a percent-encoded CRLF in the filename is escaped, not left decodable" \
    "$(find_workflow_call_targets "${workflows_dir}" | grep '0D')" "%25"
rm -f "${workflows_dir}/%0D%0A::add-mask::pwned.yml"

# A git-tracked filename may legally contain an embedded newline - see
# annotation-sanitize.sh's own header for why an unstripped one would let
# the annotation's own text forge a second, attacker-controlled workflow
# command. Asserted by LINE COUNT rather than by content: if the embedded
# newline survived unstripped, printing this one name via `printf '%s\n'`
# would itself introduce an extra line break, so two target files would
# come out as three printed lines instead of two.
newline_name="$(printf 'evil\n::add-mask::pwned.yml')"
touch "${workflows_dir}/${newline_name}" 2>/dev/null || {
    echo "SKIP: this filesystem rejects filenames containing a newline; embedded-newline sanitising is untested here."
}
if [ -e "${workflows_dir}/${newline_name}" ]; then
    cat > "${workflows_dir}/${newline_name}" <<'EOF'
on:
    workflow_call:
EOF
    targets="$(find_workflow_call_targets "${workflows_dir}")"
    assert_eq "find_workflow_call_targets: an embedded newline in the filename does not add an extra printed line" \
        "2" "$(printf '%s\n' "${targets}" | grep -c .)"
    rm -f "${workflows_dir}/${newline_name}"
fi

# --- assert_readme_catalog_complete() ---

readme_file="${work_dir}/README.md"

cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a fully-documented catalog returns 0" "0" "${rc}"
assert_eq "assert_readme_catalog_complete: a fully-documented catalog prints nothing" "" "${output}"

# End-to-end: a .yaml-extension target flows through the full completeness
# assertion, not just find_workflow_call_targets() in isolation.
cat > "${workflows_dir}/e2e.yaml" <<'EOF'
on:
    workflow_call:
EOF

cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `e2e.yaml` | End-to-end .yaml coverage | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a documented .yaml-extension target passes end-to-end" "0" "${rc}"

cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: an undocumented .yaml-extension target fails end-to-end" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: an undocumented .yaml-extension target names itself in its ::error::" \
    "${output}" "::error::" "e2e.yaml" "not listed in README.md"

rm -f "${workflows_dir}/e2e.yaml"

# A README.md missing its final newline (a common editor/save-without-
# final-newline shape) must not lose the catalog's last row: this pins
# `sed`'s own handling of an unterminated final line during table
# extraction. `printf` (no `EOF\n` heredoc terminator) constructs this
# exact shape.
printf '| Workflow | Purpose | Permissions |\n| --- | --- | --- |\n| `real.yml` | Does the real thing | `contents: read` |' \
    > "${readme_file}"

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a catalog row on the file's last line, with no trailing newline, is still found" \
    "0" "${rc}"

cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a missing entry returns non-zero" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a missing entry names the workflow in its ::error::" \
    "${output}" "::error::" "real.yml" "not listed in README.md"

# A free-standing prose mention of the filename, in backticks, is NOT a
# catalog-table row - the exact shape a bare substring grep would wrongly
# accept as "documented".
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |

Unrelated prose that happens to mention `real.yml` without documenting it
as a catalog entry.
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a bare prose mention (not a table row) still fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a bare prose mention names the workflow in its ::error::" \
    "${output}" "::error::" "real.yml" "not listed in README.md"

# A row shaped exactly like a catalog entry, but living in a DIFFERENT
# table using the same `| \`name\` | ... |` row shape, must NOT satisfy
# the check - only a row inside the MAIN catalog table (the block from
# its own header through the next blank line) counts as "documented".
# (readme-catalog-check.sh's own docstring carries the one re-derivable
# claim that README.md has a real table matching this fixture's shape.)
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |

### Inputs

| Workflow | Input | Default |
| --- | --- | --- |
| `real.yml` | `some-input` — not a catalog row | `false` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a row in a DIFFERENT table (e.g. Inputs) still fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: an Inputs-only row names the workflow in its ::error::" \
    "${output}" "::error::" "real.yml" "not listed in README.md"

# --- the reverse direction (issue #116): a catalog row with no living target ---

# A catalog row whose file was removed (or renamed) - the forward walk
# above cannot see it: it iterates files, never README rows.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `gone.yml` | Removed long ago | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a catalog row for a removed file fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a removed file's row names itself and the cause in its ::error::" \
    "${output}" "::error::" "gone.yml" "is missing" "restore the file"

# A catalog row whose file still exists but no longer declares
# workflow_call: (de-reusabled) - mentions-only.yml above is exactly that
# shape: present, `on: push` only.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `mentions-only.yml` | Used to be reusable | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a catalog row for a file that no longer declares workflow_call: fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a de-reusabled file's row names itself and the cause in its ::error::" \
    "${output}" "::error::" "mentions-only.yml" "declares no workflow_call" "restore the trigger"

# Both directions at once: a half-fixed rename leaves the OLD row behind
# while the NEW file is undocumented - one run reports both.
cat > "${workflows_dir}/renamed-old-name.yml" <<'EOF'
on:
    workflow_call:
EOF
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `old-name.yml` | Row left behind by a rename | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a half-fixed rename fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a half-fixed rename reports the undocumented new file" \
    "${output}" "renamed-old-name.yml" "not listed in README.md"
# The old name is a SUBSTRING of the new one on purpose: a membership test
# that matched by substring or glob instead of the whole line would accept
# the stale row as documented and this assertion would fail.
assert_contains "assert_readme_catalog_complete: a half-fixed rename reports the stale old row" \
    "${output}" "old-name.yml" "is missing"
assert_eq "assert_readme_catalog_complete: a half-fixed rename emits exactly one ::error:: per direction" \
    "2" "$(printf '%s\n' "${output}" | grep -c '::error::')"
rm -f "${workflows_dir}/renamed-old-name.yml"

# A stale row whose only backticked cell is the name (double space before
# the next pipe, no backticks later in the row) is still a catalog row: the
# match requires only the name's OWN closing backtick immediately followed
# by (optional space and) the column pipe - a later cell's own backticks,
# if any, are irrelevant.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `gone.yml`  | Sloppy row, no later backtick | contents: read |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a stale row without a later backticked cell still fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a stale row without a later backticked cell names itself" \
    "${output}" "gone.yml" "is missing"

# A name cell whose OWN backtick is left unclosed, while a LATER cell in
# the same row does carry backticks, must not mis-extract into that later
# cell's text: the pattern's `[^\`|]*` name class stops at the first
# backtick OR pipe it meets, so it can never cross into a later column.
# Confirmed on the shape most likely to occur for real: the Purpose text
# itself references another backtick-quoted file, as this repo's own
# label-sync.yml/i18n.yml/php-quality.yml/auto-merge-deps.yml rows do
# (re-derive: `grep -c '| \`[a-z0-9_-]*\.yml\` | [^|]*\`' README.md`).
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `sloppy.yml | Applies the canonical set from `other.yml` | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a name cell without its own closing backtick fails, even with a Purpose-column backtick present" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a name cell without its own closing backtick names the real defect, not a garbled filename" \
    "${output}" "::error::" "not a single backtick-quoted name"
assert_eq "assert_readme_catalog_complete: real.yml stays undisturbed by the malformed sibling row" \
    "1" "$(printf '%s\n' "${output}" | grep -c '::error::')"

# A name cell whose backtick is NEVER closed anywhere in the line must not
# be silently treated as "not a catalog row" the way the table
# header/separator lines are - the header is recognised by its own exact
# text and the separator only immediately after it, so a row with no
# backtick at all, appearing anywhere else, is never mistaken for either
# and still gets validated.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `totally-unclosed.yml is missing its closing backtick and nothing else has one |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a name cell with no closing backtick anywhere in the row fails, not a silent skip" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a name cell with no closing backtick anywhere in the row names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"
assert_eq "assert_readme_catalog_complete: a name cell with no closing backtick anywhere produces exactly one ::error::, not a second fallthrough line" \
    "1" "$(printf '%s\n' "${output}" | grep -c '::error::')"

# A stale row left in plain text, with NO backtick anywhere - the single
# most ordinary manual-edit slip (forgetting the markdown formatting
# entirely when leaving a row behind) - is structurally identical in shape
# to the table header ("| word | word | word |"); only matching the
# header's own exact text, never a data row's shape, tells them apart.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| gone.yml | Removed long ago | contents: read |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a plain-text stale row with no backticks at all fails, not a silent pass" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a plain-text stale row names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"

# This repository's own README rows use MULTIPLE backtick-quoted segments
# in the Permissions column (re-derive: `grep -c '\`, \`' README.md`) - a
# positive control that the name-capture class stops at the name's own
# closing backtick regardless of how many further backtick pairs follow in
# later columns.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read`, `security-events: write` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a well-formed row with multiple backtick-quoted Permissions segments passes" "0" "${rc}"
assert_eq "assert_readme_catalog_complete: a well-formed row with multiple backtick-quoted Permissions segments prints nothing" \
    "" "${output}"

# A table missing its GFM alignment separator (a plausible manual-edit
# slip - GFM tables render as plain text without it, so the mistake is not
# always visually obvious) must not shift the first real data row into a
# position an earlier, position-counting implementation treated as fixed
# furniture: the separator is only ever recognised on the line immediately
# after a recognised header, so its absence simply means that slot falls
# through to ordinary row validation, and a stale row there is still
# caught regardless of whether the table around it is otherwise
# well-formed.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| `gone.yml` | Removed long ago | `contents: read` |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a stale row survives even when the table is missing its separator row" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a stale row missing the separator row names itself" \
    "${output}" "gone.yml" "is missing"

# The colon-alignment separator variants (left/center/right) are equally
# recognised as furniture by the same "only |, -, : and whitespace" shape.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
|:---|:---:|---:|
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a colon-alignment separator is still recognised as furniture" "0" "${rc}"

# A duplicated header line inside the table body is itself recognised as
# furniture (its exact text can never be mistaken for a data row, since a
# real catalog row always needs a backtick-quoted name) and does not
# disturb validation of the real rows around it.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| Workflow | Purpose | Permissions |
| `gone.yml` | Removed long ago | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a duplicated header line does not disturb the stale row after it" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a duplicated header line's neighbour still names the real defect" \
    "${output}" "gone.yml" "is missing"

# A row consisting only of separator-shaped characters (pipes, dashes,
# colons, whitespace) - a plausible blanked-out or duplicated-separator
# manual-edit slip - must not be silently treated as furniture merely
# because of its shape when it does NOT sit immediately after the header:
# four independent review lanes reproduced this exact silent pass live
# (rc=0, no ::error::) against an earlier, position-unaware content check
# (issue #116).
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| - | - | - |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a separator-shaped row NOT immediately after the header fails, not a silent skip" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a separator-shaped row elsewhere in the table names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"
assert_eq "assert_readme_catalog_complete: real.yml stays undisturbed by the separator-shaped sibling row" \
    "1" "$(printf '%s\n' "${output}" | grep -c '::error::')"

# A mid-table duplicate of the true separator line itself is the same
# shape, at the same non-header-adjacent position, and must fail the same
# way rather than being silently re-recognised as furniture a second time.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| --- | --- | --- |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a mid-table duplicate of the separator line fails, not a silent skip" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a mid-table duplicate of the separator line names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"

# A separator-shaped line WITHOUT a single dash (a blanked-out row that
# kept only its pipe skeleton) must fail closed even in the one slot -
# immediately after the header - where a genuine separator IS recognised:
# real GFM alignment cells always carry at least one dash, so a dashless
# line there is not a separator, it is a malformed row with no separator
# present at all.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| | | |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a dashless pipe/whitespace row right after the header fails, not a silent skip" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a dashless pipe/whitespace row after the header names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"
assert_eq "assert_readme_catalog_complete: real.yml is still validated normally right after the dashless row" \
    "1" "$(printf '%s\n' "${output}" | grep -c '::error::')"

# A dash present ANYWHERE in the line is not enough: a single-cell line
# whose dash sits with whitespace around it, not forming a contiguous
# per-cell alignment run, must still fail closed right after the header.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| : - - : |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a dash-containing but non-cell-shaped row right after the header fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a dash-containing but non-cell-shaped row names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"

# A dash present in only ONE cell of a multi-cell line, with the other
# cells blank, must also fail closed right after the header - the dash
# has to belong to a real alignment cell, not merely appear somewhere in
# the line's punctuation.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| | - | |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a lone dash in one cell of an otherwise blank row right after the header fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a lone dash in one cell of an otherwise blank row names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"

# The separator regex's outer `+` (one-or-more cells) is load-bearing on
# its own: a bare `|` right after the header has zero cells, so weakening
# `+` to `*` (zero-or-more) would let it match as an empty separator -
# every existing fixture stays green under that weakening, since none of
# them exercises a zero-cell line.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
|
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a bare pipe with zero cells right after the header fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a bare pipe with zero cells names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"

# The regex's `^`/`$` anchors are the only guard against a substring
# match, since bash's `[[ =~ ]]` has no implicit anchoring: a separator
# preceded or followed by extra content on the same line must still fail
# closed rather than being accepted as furniture with the garbage
# silently ignored.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
x| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a separator with leading garbage right after the header fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a separator with leading garbage names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"

cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |x
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a separator with trailing garbage right after the header fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a separator with trailing garbage names the real defect" \
    "${output}" "::error::" "not a single backtick-quoted name"

# The mandatory single space between the leading pipe and the opening
# backtick (matching the forward loop's own `"| \`${name}\` |"*` literal)
# is deliberately strict, not merely untested: a row missing it is not a
# row the forward direction recognises as documenting its target either,
# so BOTH directions report it - the forward loop as "not listed", the
# reverse walk as "not a single backtick-quoted name" - rather than one
# silently deferring to the other. Pinned here so a future change to
# either regex in isolation is caught by this test noticing the count
# drop to one.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
|`real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a name cell with no leading space fails closed in both directions" "1" "${rc}"
assert_eq "assert_readme_catalog_complete: a name cell with no leading space produces exactly two ::error:: lines, one per direction" \
    "2" "$(printf '%s\n' "${output}" | grep -c '::error::')"

# The membership test's `-F` (fixed-string) flag matters: without it, a
# stale row name containing a literal `.` would let that `.` act as a
# regex "any character" wildcard under `grep`'s own BRE, matching a real
# target that merely has a DIFFERENT character in that position - a false
# negative that would let a genuinely stale, differently-named row escape
# detection.
cat > "${workflows_dir}/v1X0.yml" <<'EOF'
on:
    workflow_call:
EOF
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `v1X0.yml` | Versioned entry point | `contents: read` |
| `v1.0.yml` | A different, stale name that only a wildcard `.` could confuse with v1X0.yml | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a stale row whose name differs from a real target only by a literal dot still fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: the dot-differing stale row names itself, not the real v1X0.yml target" \
    "${output}" "v1.0.yml" "is missing"
rm -f "${workflows_dir}/v1X0.yml"

# A row in a DIFFERENT table naming a non-target is not a stale catalog
# row - the reverse direction is scoped to the main catalog table exactly
# like the forward one.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |

### Inputs

| Workflow | Input | Default |
| --- | --- | --- |
| `gone.yml` | `some-input` — not a catalog row | `false` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a non-target row in a DIFFERENT table is not reported as stale" "0" "${rc}"

# A stale row's NAME comes from README, not from the filesystem, so it is
# a second caller-controlled input into a ::error:: line - it must route
# through sanitize_for_annotation() like the filesystem-side names do.
# Pinned by SHADOWING the sanitizer (the file's own technique for mktemp and
# find_workflow_call_targets below): a hand-rolled `%`-escape in its place -
# the private-copy drift issue #78 documents - would pass a `%25` needle
# but never print this sentinel. The definition is saved and restored via
# `declare -f` rather than re-sourced, because annotation-sanitize.sh
# declares a readonly constant a second source would trip over (re-derive:
# `grep -n readonly ../lib/annotation-sanitize.sh`).
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `%0D%0A::add-mask::gone.yml` | Forged row | `contents: read` |
EOF

real_sanitizer="$(declare -f sanitize_for_annotation)"
sanitize_for_annotation() { printf 'SANITIZED<%s>' "$1"; }
output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
eval "${real_sanitizer}"
assert_eq "assert_readme_catalog_complete: a forged stale row still fails" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a stale row's name is routed through sanitize_for_annotation() itself" \
    "${output}" "SANITIZED<%0D%0A::add-mask::gone.yml> is listed"

# The positive control for the raw-vs-sanitised membership the lib's own
# comment calls deliberate: a target whose filename sanitize_for_annotation()
# folds, documented under its FOLDED name, passes both directions. A
# membership test that sanitised the row a second time would flag this row
# as stale on a README that is consistent with the forward rule.
cat > "${workflows_dir}/%0D%0A::add-mask::pwned.yml" <<'EOF'
on:
    workflow_call:
EOF
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `%250D%250A::add-mask::pwned.yml` | Documented under its folded name | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a target documented under its sanitised name is accepted by BOTH directions" "0" "${rc}"
assert_eq "assert_readme_catalog_complete: a target documented under its sanitised name prints nothing" "" "${output}"
rm -f "${workflows_dir}/%0D%0A::add-mask::pwned.yml"

# Zero targets at all (a workflows dir with no workflow_call: file), plus an
# empty backtick cell and a row for a trigger-less file: the reverse walk
# must still fail closed. With zero targets the names list is one empty
# line, which an unguarded empty row would match - the silent pass the
# empty-cell guard exists for.
zero_dir="${work_dir}/workflows-zero"
mkdir -p "${zero_dir}"
cat > "${zero_dir}/plain.yml" <<'EOF'
on:
    push:
EOF
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `` | Empty name | `contents: read` |
| `plain.yml` | Not reusable | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${zero_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: zero targets plus an empty backtick cell fails, not a silent pass" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: an empty backtick cell is reported as naming no workflow" \
    "${output}" "::error::" "names no workflow"
assert_contains "assert_readme_catalog_complete: with zero targets a row for a trigger-less file is reported" \
    "${output}" "plain.yml" "declares no workflow_call"
assert_eq "assert_readme_catalog_complete: zero targets, two bad rows, exactly two ::error:: lines" \
    "2" "$(printf '%s\n' "${output}" | grep -c '::error::')"

# The empty-cell guard's `continue` matters even when it is NOT masked by
# an empty names list: with a real target present, a missing `continue`
# would fall through into the membership grep for the empty row and print
# a second, filename-less ::error:: line - the zero-targets case above
# cannot catch that, because there an empty needle trivially matches the
# single empty line names holds regardless of the guard.
cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
| `` | Empty name | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: an empty backtick cell fails alongside a real, documented target" "1" "${rc}"
assert_eq "assert_readme_catalog_complete: an empty backtick cell produces exactly one ::error::, not a second fallthrough line" \
    "1" "$(printf '%s\n' "${output}" | grep -c '::error::')"

# A REAL python3 failure (not a per-file skip, and not the whole bash
# function shadowed below) must still propagate through
# find_workflow_call_targets() itself - pinning the `python3 ... || rc=$?`
# / `[ "${rc}" -ne 0 ]` line directly, since the crashed-producer test below
# only proves assert_readme_catalog_complete()'s OWN exit-code handling by
# replacing the whole function, never exercising this line at all. Nested
# under work_dir (matching test-semgrepignore-guard.sh's fake_jq_dir), not a
# free-standing mktemp -d with its own rm -rf: the top-level `trap 'rm -rf
# "${work_dir}"' EXIT` above then covers it too, so it cannot leak even if a
# future edit adds an early return between creating it and cleaning it up.
python3_stub_dir="$(mktemp -d "${work_dir}/python3-stub-XXXXXX")" || exit 1
cat > "${python3_stub_dir}/python3" <<'EOS'
#!/usr/bin/env bash
exit 3
EOS
chmod +x "${python3_stub_dir}/python3"

real_targets_rc=0
PATH="${python3_stub_dir}:${PATH}" find_workflow_call_targets "${workflows_dir}" > /dev/null || real_targets_rc=$?

# Exit 3, not 1: a mutant that hardcodes `return 1` on python3 failure
# (instead of `return "${rc}"`, propagating the real exit code) would still
# pass an rc==1 assertion by coincidence - this pins the actual value, not
# merely "non-zero".
assert_eq "find_workflow_call_targets: a real python3 failure propagates its real exit code" \
    "3" "${real_targets_rc}"

# The mktemp guard fails closed rather than proceeding with an empty
# variable - mirrors test-warn-tracked-archives.sh's own shadowed-mktemp
# technique for the same shape. Asserting the exit code alone is not
# enough to pin this: with the `|| return 1` guard removed, `python3 ...
# > ""` (an empty redirect target) ALSO fails and ALSO returns non-zero -
# not from python3, from bash's own "No such file or directory" on the
# empty redirect target, which happens BEFORE bash even attempts to exec
# python3. Mutation-confirmed live (both with and without the guard, and
# also confirmed that a python3-stub sentinel file is unwritten in BOTH
# cases either way, since bash never reaches the point of running the
# command it would redirect into - a sentinel-based test would have been
# equally vacuous). What DOES discriminate: the guard's own `return 1` is
# silent, while bash's own redirect-failure message goes to stderr - so
# asserting stderr is EMPTY proves the guard fired before that line was
# ever reached, not merely that the function eventually returned
# non-zero somehow. Run BEFORE find_workflow_call_targets() itself is
# shadowed away below: `unset -f` on a function that was REDEFINED (not
# merely wrapped) deletes it outright rather than restoring the original
# sourced definition, so this is the last point in the file where the
# real function is still callable.
mktemp() { return 1; }
find_workflow_call_targets_mktemp_rc=0
find_workflow_call_targets_mktemp_stderr="$(find_workflow_call_targets "${workflows_dir}" 2>&1 >/dev/null)" || find_workflow_call_targets_mktemp_rc=$?
unset -f mktemp
assert_eq "find_workflow_call_targets: a mktemp failure returns non-zero" \
    "1" "${find_workflow_call_targets_mktemp_rc}"
assert_eq "find_workflow_call_targets: a mktemp failure returns silently, before the python3 redirect line" \
    "" "${find_workflow_call_targets_mktemp_stderr}"

# A crashed producer must fail the whole check LOUDLY, not silently report
# "zero targets" - the exact defect found and fixed during the issue #118
# audit (assert_readme_catalog_complete() used to consume
# find_workflow_call_targets() via `done < <(...)`, whose exit status bash
# never propagates into the enclosing shell). Shadowing the function itself
# (rather than crafting a real file that crashes find_workflow_call_targets.py)
# isolates this from the per-file skip path already covered above, and pins
# the CALLER's own exit-code handling regardless of what happens to ever
# make the Python script fail outright in the future.
find_workflow_call_targets() { return 1; }

cat > "${readme_file}" <<'EOF'
| Workflow | Purpose | Permissions |
| --- | --- | --- |
| `real.yml` | Does the real thing | `contents: read` |
EOF

output="$(assert_readme_catalog_complete "${workflows_dir}" "${readme_file}")"
rc=$?
assert_eq "assert_readme_catalog_complete: a crashed producer fails closed, not silently 'zero targets'" "1" "${rc}"
assert_contains "assert_readme_catalog_complete: a crashed producer names itself in its ::error::" \
    "${output}" "::error::" "find_workflow_call_targets failed"

unset -f find_workflow_call_targets

report_and_exit "readme-catalog-check tests"
