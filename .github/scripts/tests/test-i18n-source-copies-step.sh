#!/usr/bin/env bash
# Runs the "Look for catalogue entries that repeat their source text" step of
# i18n.yml against caller trees, so the shell logic around the Python check is
# covered: the default and the gate of the job, the exit status that reaches
# the runner and the removal of the shared checkout. The Python check itself is
# covered by test_i18n_source_copies.py.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/i18n.yml"

failures=0
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

# Extract the run block of the step, the way the runner would execute it.
python3 - "${WORKFLOW}" "${workdir}/step.sh" <<'EOF' || { echo "FAIL: cannot extract the step"; exit 1; }
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

steps = workflow["jobs"]["source-copies"]["steps"]
step = [s for s in steps if s.get("name", "").startswith("Look for catalogue entries")][0]

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(step["run"])
EOF

# The job runs by default and only the input switches it off.
python3 - "${WORKFLOW}" <<'EOF2' || fail "the source copies job is not on by default or not gated by its input"
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

# YAML 1.1 reads the key "on" as the boolean true.
triggers = workflow.get("on", workflow.get(True))
inputs = triggers["workflow_call"]["inputs"]
assert inputs["check-source-copies"]["default"] is True, "default"
assert inputs["check-source-copies"]["type"] == "boolean", "type"
assert workflow["jobs"]["source-copies"]["if"].strip() == "${{ inputs.check-source-copies }}", "gate"
EOF2

write_po() {
    # write_po FILE MSGID MSGSTR
    mkdir -p "$(dirname "$1")"
    printf 'msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "%s"\nmsgstr "%s"\n' "$2" "$3" > "$1"
}

# Runs the step in a fresh caller tree. Arguments: locale directory name,
# msgstr, lang dir input. The result is left in $out and $rc.
run_step() {
    local locale="$1" msgstr="$2" lang_dir="${3:-resources/lang}"
    local caller="${workdir}/caller"

    rm -rf "${caller}"
    mkdir -p "${caller}"
    write_po "${caller}/resources/lang/${locale}/messages.po" "Portal" "${msgstr}"
    ln -s "${REPO_ROOT}" "${caller}/.magicsunday-shared"

    out="$(cd "${caller}" && LANG_DIR="${lang_dir}" bash "${workdir}/step.sh" 2>&1)"
    rc=$?
}

assert() {
    # assert DESCRIPTION EXPECTED_RC PATTERN
    if [ "${rc}" -ne "$2" ]; then
        fail "$1: expected exit $2, got ${rc}: ${out}"
        return
    fi
    if [ -n "$3" ] && ! grep -q -- "$3" <<<"${out}"; then
        fail "$1: output lacks '$3': ${out}"
    fi
}

run_step de "Portal"
assert "a copy fails with the file and line" 1 "::error file=resources/lang/de/messages.po,line="
[ ! -e "${workdir}/caller/.magicsunday-shared" ] || fail "the shared checkout stays after a failing run"

run_step de ""
assert "an empty entry passes" 0 "No catalogue entry repeats"
[ ! -e "${workdir}/caller/.magicsunday-shared" ] || fail "the shared checkout stays after a passing run"

run_step en-GB "Portal"
assert "a copy in the en-GB catalogue fails too" 1 "en-GB"

run_step de "Zugang"
assert "a real translation passes" 0 "No catalogue entry repeats"

run_step de "Portal" "resources/lang/"
assert "a trailing slash of the directory input is accepted" 1 "::error file="

run_step de "Portal" "resources/missing"
assert "a missing directory exits with the input error status" 2 "does not exist"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} assertion(s) failed."
    exit 1
fi

echo "All i18n source copies step tests passed."
