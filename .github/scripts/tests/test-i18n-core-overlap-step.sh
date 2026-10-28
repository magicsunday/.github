#!/usr/bin/env bash
# Runs the "Compare the catalogues with webtrees core" step of i18n.yml against
# stubbed git and curl, so the shell logic around the Python check is covered:
# the choice of core tags, the checks that keep a mistyped tag from reading as
# clean, the locale name restriction and the HTTP status handling. The Python
# check itself is covered by test_i18n_core_overlap.py.
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

steps = workflow["jobs"]["core-overlap"]["steps"]
step = [s for s in steps if s.get("name", "").startswith("Compare the catalogues")][0]

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(step["run"])
EOF

# The job runs by default and only the input switches it off.
python3 - "${WORKFLOW}" <<'EOF2' || fail "the core overlap job is not on by default or not gated by its input"
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

# YAML 1.1 reads the key "on" as the boolean true.
triggers = workflow.get("on", workflow.get(True))
inputs = triggers["workflow_call"]["inputs"]
assert inputs["check-core-overlap"]["default"] is True, "default"
assert inputs["check-core-overlap"]["type"] == "boolean", "type"
assert workflow["jobs"]["core-overlap"]["if"].strip() == "${{ inputs.check-core-overlap }}", "gate"
EOF2

# Stubs: git ls-remote prints the release list, curl serves a file from the
# fixture directory named by the URL tail, or the status given in STUB_STATUS.
mkdir -p "${workdir}/bin"
cat > "${workdir}/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "ls-remote" ]; then
    printf 'abc\trefs/tags/2.1.27\nabc\trefs/tags/2.2.0\nabc\trefs/tags/2.2.1\nabc\trefs/tags/2.3.0\n'
    exit 0
fi
exec /usr/bin/git "$@"
EOF
cat > "${workdir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift ;;
        --write-out|--retry) shift ;;
        http*) url="$1" ;;
    esac
    shift
done
if [ -n "${STUB_STATUS:-}" ]; then
    printf '%s' "${STUB_STATUS}"
    exit 0
fi
tail="${url#*webtrees/}"
tag="${tail%%/*}"
locale="${tail#*/resources/lang/}"
locale="${locale%%/*}"
source_file="${CORE_FIXTURES}/${tag}/${locale}/messages.po"
if [ -f "${source_file}" ]; then
    cp "${source_file}" "${output}"
    printf '200'
else
    : > "${output}"
    printf '404'
fi
EOF
chmod +x "${workdir}/bin/git" "${workdir}/bin/curl"

write_po() {
    # write_po FILE MSGID MSGSTR
    mkdir -p "$(dirname "$1")"
    printf 'msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "%s"\nmsgstr "%s"\n' "$2" "$3" > "$1"
}

# Runs the step in a fresh caller tree. Arguments: core-tags, constraint,
# module msgstr, locale directory name. The result is left in $out and $rc.
run_step() {
    local core_tags="$1" constraint="$2" msgstr="$3" locale="${4:-nn}"
    local caller="${workdir}/caller"

    rm -rf "${caller}" "${workdir}/fixtures"
    mkdir -p "${caller}"
    printf '{"require": {"fisharebest/webtrees": "%s"}}\n' "${constraint}" > "${caller}/composer.json"
    write_po "${caller}/resources/lang/${locale}/messages.po" "Details" "${msgstr}"
    write_po "${workdir}/fixtures/2.2.0/nn/messages.po" "Details" "Detaljar"
    write_po "${workdir}/fixtures/2.2.1/nn/messages.po" "Details" "Detaljar"
    if [ -z "${OMIT_DE:-}" ]; then
        for tag in 2.1.27 2.2.0 2.2.1 2.3.0; do
            write_po "${workdir}/fixtures/${tag}/de/messages.po" "Details" "Details"
        done
    fi
    ln -s "${REPO_ROOT}" "${caller}/.magicsunday-shared"

    out="$(cd "${caller}" && PATH="${workdir}/bin:${PATH}" LANG_DIR=resources/lang CORE_TAGS="${core_tags}" \
        CORE_FIXTURES="${workdir}/fixtures" STUB_STATUS="${STUB_STATUS:-}" bash "${workdir}/step.sh" 2>&1)"
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

run_step "" "~2.2.0" "Detaljar"
assert "a filled core text fails with the file and line" 1 "::error file=resources/lang/nn/messages.po,line="
grep -q "release 2.2.0, 2.2.1" <<<"${out}" || fail "the tags are derived from the composer constraint: ${out}"

run_step "" "~2.2.0" ""
assert "an empty entry passes" 0 "No catalogue entry overrides"

run_step "2.2.1" "~2.2.0" "Detaljar"
assert "explicit tags win over the constraint" 1 "release 2.2.1)"

run_step "   " "~2.2.0" ""
assert "whitespace-only core-tags derive the tags" 0 "Comparing with webtrees core releases: 2.2.0 2.2.1"

run_step "9.9.9" "~2.2.0" "Detaljar"
assert "an unknown explicit tag fails" 1 "'9.9.9' is not a webtrees release tag"

run_step "" ">=2.2" "Detaljar"
assert "an unusable constraint shows the reason" 1 "pass the core tags explicitly"

run_step "2.1.27" "~2.2.0" "Detaljar"
assert "a release that has no catalogue of the module locale passes" 0 "No catalogue entry overrides"

run_step "" "~2.2.0" "Detaljar" "xx"
assert "a module with only locales that core does not ship passes" 0 "No catalogue entry overrides"

OMIT_DE=1 run_step "" "~2.2.0" "Detaljar"
assert "a missing german catalogue means the core layout changed" 1 "layout of the core repository changed"

run_step "" "~2.2.0" "Detaljar" 'de,x'
assert "a directory name that is no locale tag fails before any request" 1 "is not a locale tag"

run_step "" "~2.2.0" "Detaljar" $'de\n::add-mask::x'
assert "a directory name with a line break fails" 1 "'de???add-mask??x' is not a locale tag"
[ "$(grep -c '^::add-mask::' <<<"${out}")" -eq 0 ] || fail "the rejected directory name starts a workflow command: ${out}"

STUB_STATUS=500 run_step "" "~2.2.0" ""
assert "an unexpected HTTP status fails" 1 "returned HTTP 500"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} assertion(s) failed."
    exit 1
fi

echo "All i18n core overlap step tests passed."
