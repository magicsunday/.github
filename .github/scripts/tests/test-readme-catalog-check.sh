#!/usr/bin/env bash
# Exercises find_workflow_call_targets() and assert_readme_catalog_complete()
# (.github/scripts/lib/readme-catalog-check.sh), the functions lint.yml's
# "readme-catalog-fresh" job sources to keep README.md's workflow catalog
# honest against the real *.yml files (issue #101). Run via run-tests.sh.
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

# A percent-encoded CRLF (`%0D%0A`) in a filename is a SEPARATE forgery
# channel from a raw control byte: the Actions runner decodes an
# already-escaped `%0D`/`%0A` sequence back to a real CRLF at render time,
# indistinguishable from literal `%0D%0A` text in the source data unless a
# bare `%` is escaped to `%25` first (annotation-sanitize.sh's own
# rationale). A plain `tr -d '\r\n'` does not see this channel at all,
# since no raw CR/LF byte is present until the runner decodes it - only
# routing through sanitize_for_annotation() closes it.
touch "${workflows_dir}/%0D%0A::add-mask::pwned.yml"
cat > "${workflows_dir}/%0D%0A::add-mask::pwned.yml" <<'EOF'
on:
    workflow_call:
EOF
assert_eq "find_workflow_call_targets: a percent-encoded CRLF in the filename is escaped, not left decodable" \
    "%250D%250A::add-mask::pwned.yml" \
    "$(find_workflow_call_targets "${workflows_dir}" | grep '0D')"
rm -f "${workflows_dir}/%0D%0A::add-mask::pwned.yml"

# A git-tracked filename may legally contain an embedded newline; this
# value later becomes part of a ::error:: workflow-command annotation, so
# an unstripped newline would let the annotation's own text forge a second,
# attacker-controlled workflow command. Asserted by LINE COUNT rather than
# by content: if the embedded newline survived unstripped, printing this
# one name via `printf '%s\n'` would itself introduce an extra line break,
# so two target files would come out as three printed lines instead of two.
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

report_and_exit "readme-catalog-check tests"
