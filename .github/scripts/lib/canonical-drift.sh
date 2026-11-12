#!/usr/bin/env bash
# Sourced by canonical-drift.yml's "Check every repository for canonical-file
# drift" step and by .github/scripts/tests/test-canonical-drift.sh, so the
# workflow and its test drive the same file rather than two copies that can
# drift apart.
#
# The scheduled, account-wide half of canonical-file enforcement (issue #87).
# canonical-file-guard.sh is the reactive half: it fires inside zizmor.yml, so
# it only ever sees a repository that already calls that gate. This sweep
# enumerates every non-archived, non-fork repository the account owns and
# compares each manifest entry by git blob hash, which is one contents-API
# call per file (plus one per repository for an `applies_when_present` path)
# and needs no download: identical bytes give an identical blob hash.
#
# It reports and never writes - opening a pull request per drifted repository
# is the obvious follow-up once the canonical set is stable.
#
# Which files are canonical is declared in .github/canonical-files.json, and
# the canonical CONTENT of each `files` entry is this repository's own copy at
# the same path. The manifest therefore only names paths; there is no second
# copy of the content to fall out of step with the file it describes, and
# assert_canonical_manifest_valid() fails the run if a listed path does not
# exist here.
#
# A second kind of entry, `template_sets`, covers the shared release files of
# the ZIP webtrees modules. Their canonical content is a directory of another
# repository's default branch (the template of coding-standard), read through
# the API at sweep time, so this repository holds no third copy. Every file of
# that directory except the listed exclusions is compared with the same path in
# each named repository, which is the file set that the template's own sync
# script copies. The PHP files differ per module in their identity lines (the
# package name and the namespace), so for a `.php` file the template text is
# rendered with the module's MODULE_NAME and MODULE_NS, read from the parameter
# file of the module, before its blob hash is compared. That is the same
# rendering the sync script does, with the same shape checks on both values.
#
# Coverage limit, stated rather than hidden: the sweep runs on this
# repository's own GITHUB_TOKEN, which can read another repository only while
# that repository is public. A private repository is not listed and not
# checked.
#
# Printed values and where they come from. An account or repository name, a
# count, a path from this repository's own manifest and the source repository
# and directory of a template set are maintainer input or constrained by
# GitHub's naming rules (a username may contain only alphanumerics and dashes,
# a repository name only ASCII letters, digits, `.`, `-` and `_`) and are
# printed as written. A file path read from the tree listing of a template
# repository is the one value that another repository controls. It passes
# through annotation-sanitize.sh (_canonical_drift_label) before it reaches an
# annotation or a report row, and it travels base64 encoded between the
# listing and its use, so a newline in it cannot split a line.
#
# check_canonical_drift runs every call whose non-zero status is an expected
# answer in a tested context (`|| rc=$?`, `|| return 1`, `if !`), and
# classify_canonical_entry answers through what it prints rather than its
# status: canonical-drift.yml calls the sweep under `set -euo pipefail`,
# where a bare failing call would end it before it reports anything.

# shellcheck source=annotation-sanitize.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotation-sanitize.sh"

# Per page of `GET /users/{owner}/repos`: the repositories worth checking.
# Archived repositories are frozen and forks mirror an upstream, so neither is
# expected to carry this account's canonical files (issue #38's open question
# on membership, settled here).
readonly CANONICAL_DRIFT_REPO_FILTER='.[] | select((.archived | not) and (.fork | not)) | .name'

# Prints the git blob hash of file "$2" (relative to repository root "$1")
# as git stores it: hashed from inside that repository, so a .gitattributes
# line-ending rule is applied the way `git add` would and a CRLF checkout
# still yields the LF blob the contents API reports.
canonical_blob_sha() {
    git -C "$1" hash-object -- "$2"
}

# Validates manifest "$1" against canonical root "$2": a non-empty `files`
# array, every `path` a string naming a regular (non-symlink) file under the
# root, and `applies_when_present`, when given, a non-empty string. When
# `template_sets` is present, each entry names a source repository, a source
# directory, a parameter file and a non-empty list of repositories, and its
# `exclude`, when given, is a list of paths. Returns 1 with an ::error:: per
# problem.
assert_canonical_manifest_valid() {
    local manifest="$1"
    local canonical_root="$2"
    local problems=0
    local count path

    if ! count="$(jq -er '.files | if type == "array" then length else error("files is not an array") end' "${manifest}" 2>/dev/null)"; then
        echo "::error::${manifest} is not valid JSON with a \"files\" array."
        return 1
    fi

    if [ "${count}" -eq 0 ]; then
        echo "::error::${manifest} lists no canonical files - the sweep would pass without checking anything."
        return 1
    fi

    local i
    for ((i = 0; i < count; i++)); do
        if ! path="$(jq -er ".files[${i}].path | strings" "${manifest}" 2>/dev/null)"; then
            echo "::error::${manifest}: files[${i}] has no string \"path\"."
            problems=$((problems + 1))
            continue
        fi

        if [ ! -f "${canonical_root}/${path}" ] || [ -L "${canonical_root}/${path}" ]; then
            echo "::error::${manifest}: ${path} is not a regular file in this repository, so it has no canonical content to compare against."
            problems=$((problems + 1))
        fi

        if ! jq -e ".files[${i}] | (has(\"applies_when_present\") | not) or (.applies_when_present | type == \"string\" and length > 0)" "${manifest}" >/dev/null 2>&1; then
            echo "::error::${manifest}: files[${i}].applies_when_present must be a non-empty string when given."
            problems=$((problems + 1))
        fi
    done

    if jq -e 'has("template_sets")' "${manifest}" >/dev/null 2>&1; then
        local set_problems
        set_problems="$(jq -r '
            .template_sets
            | if type != "array" or length == 0 then "template_sets must be a non-empty array."
              else to_entries[]
                | .key as $i | .value as $set
                | (if ($set | type) != "object" then "template_sets[\($i)] is not an object."
                   else
                       ( ["source_repository", "source_directory", "parameter_file"][]
                         | select(($set[.] | type) != "string" or ($set[.] | length) == 0)
                         | "template_sets[\($i)].\(.) must be a non-empty string." ),
                       ( select(($set.repositories | type) != "array"
                                or ($set.repositories | length) == 0
                                or ($set.repositories | map(type == "string" and length > 0) | all | not))
                         | "template_sets[\($i)].repositories must be a non-empty array of names." ),
                       ( select(($set | has("exclude"))
                                and (($set.exclude | type) != "array"
                                     or ($set.exclude | map(type == "string" and length > 0) | all | not)))
                         | "template_sets[\($i)].exclude must be an array of paths." )
                   end)
              end' "${manifest}" 2>/dev/null)" || set_problems="template_sets could not be read."

        if [ -n "${set_problems}" ]; then
            while IFS= read -r line; do
                echo "::error::${manifest}: ${line}"
                problems=$((problems + 1))
            done <<<"${set_problems}"
        fi
    fi

    [ "${problems}" -eq 0 ]
}

# Fetches `GET /<endpoint>` through `gh api`. Prints the response body and
# returns 0 on success, returns 1 on a 404, and 2 on anything else - so a
# missing file is told apart from a request that failed, which must never
# read as "missing" (or as "fine").
_canonical_drift_fetch() {
    local endpoint="$1"
    local err_file body rc

    err_file="$(mktemp)" || return 2
    body="$(gh api "${endpoint}" 2>"${err_file}")"
    rc=$?

    if [ "${rc}" -eq 0 ]; then
        rm -f "${err_file}"
        printf '%s' "${body}"
        return 0
    fi

    if grep -q '(HTTP 404)' "${err_file}"; then
        rm -f "${err_file}"
        return 1
    fi

    rm -f "${err_file}"
    return 2
}

# Classifies one contents-API response body "$1" against canonical blob hash
# "$2": prints `ok`, `drifted` (a regular file with other bytes) or
# `not-a-file` (a directory listing, a submodule, a symlink whose target is
# not a regular file - anything the canonical file cannot be). The printed
# word is the whole answer, so it always returns 0. A symlink to a regular
# file in the same repository comes back as `type: file` with the target's
# content but the symlink's own blob sha (observed against the live contents
# API on 2026-09-27), so it compares as `drifted` even when the target is
# byte-identical.
classify_canonical_entry() {
    local body="$1"
    local canonical_sha="$2"
    local kind remote_sha

    kind="$(jq -r 'if type == "object" then (.type // "") else "listing" end' <<<"${body}" 2>/dev/null)" || kind=""

    if [ "${kind}" != "file" ]; then
        printf 'not-a-file'
        return 0
    fi

    remote_sha="$(jq -r '.sha // ""' <<<"${body}" 2>/dev/null)" || remote_sha=""

    if [ -n "${remote_sha}" ] && [ "${remote_sha}" = "${canonical_sha}" ]; then
        printf 'ok'
        return 0
    fi

    printf 'drifted'
}

# Prints the value that parameter file "$1" assigns to name "$2", read the way
# make and the sync script of the template read it: a line is an assignment
# when it holds the name, optionally indented with spaces, then `=`, `:=`,
# `::=` or `?=`. The last `=`-style assignment wins and a `?=` only sets a name
# nothing set before. Whitespace around the value and a carriage return are
# dropped. Returns 1 when the file assigns the name nowhere.
_canonical_drift_module_parameter() {
    local file="$1"
    local wanted="$2"
    local assignment='^ *([A-Z][A-Z0-9_]*)[[:space:]]*(:?:?=|\?=)[[:space:]]*(.*)$'
    local line value found=1 result=""

    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" =~ ${assignment} ]] || continue
        [ "${BASH_REMATCH[1]}" = "${wanted}" ] || continue

        if [ "${BASH_REMATCH[2]}" = "?=" ] && [ "${found}" -eq 0 ]; then
            continue
        fi

        value="${BASH_REMATCH[3]}"
        result="${value%"${value##*[![:space:]]}"}"
        found=0
    done <"${file}"

    printf '%s' "${result}"
    return "${found}"
}

# Decodes the base64 `content` of contents-API body "$1" into file "$2".
# Returns non-zero when the body has no content or does not decode, which is
# also what an empty body (a failed fetch prints none) amounts to.
_canonical_drift_decode_content() {
    jq -er '.content' <<<"$1" 2>/dev/null | base64 -d >"$2" 2>/dev/null
}

# Prints "$1" made safe for a workflow-command annotation (see
# annotation-sanitize.sh) and for one cell of a Markdown table row, where a
# pipe would start a new cell.
_canonical_drift_label() {
    local safe
    safe="$(sanitize_for_annotation "$1")"
    printf '%s' "${safe//|/\\|}"
}

# Compares one file of repository "$2" (owner "$1") at path "$3" with the
# canonical blob hash "$4" and records the outcome. "$5" names the canonical
# source in the message of a drift ("the template X/dir", "the canonical copy
# in X/Y"). "$6" is the path as shown in annotations and rows, which differs
# from "$3" only when the path came from another repository and had to be made
# safe first. It writes into the counters and the report rows of the
# calling sweep (checked, failures, unchecked, rows), which it sees through
# bash's dynamic scoping, so every kind of entry shares one report and one
# verdict.
_canonical_drift_compare_remote() {
    local owner="$1" repo="$2" path="$3" canonical_sha="$4" origin_label="$5" shown="$6"
    local body rc=0

    body="$(_canonical_drift_fetch "repos/${owner}/${repo}/contents/${path}")" || rc=$?
    checked=$((checked + 1))

    case "${rc}" in
        0)
            case "$(classify_canonical_entry "${body}" "${canonical_sha}")" in
                ok)
                    rows+="| ${repo} | \`${shown}\` | ok |"$'\n'
                    ;;
                drifted)
                    echo "::error::${owner}/${repo}: ${shown} differs from ${origin_label}."
                    rows+="| ${repo} | \`${shown}\` | **drifted** |"$'\n'
                    failures=$((failures + 1))
                    ;;
                *)
                    echo "::error::${owner}/${repo}: ${shown} exists but is not a regular file."
                    rows+="| ${repo} | \`${shown}\` | **not a regular file** |"$'\n'
                    failures=$((failures + 1))
                    ;;
            esac
            ;;
        1)
            echo "::error::${owner}/${repo}: ${shown} is missing."
            rows+="| ${repo} | \`${shown}\` | **missing** |"$'\n'
            failures=$((failures + 1))
            ;;
        *)
            echo "::error::${owner}/${repo}: fetching ${shown} failed, so it went unchecked."
            rows+="| ${repo} | \`${shown}\` | **unchecked** (API error) |"$'\n'
            checked=$((checked - 1))
            unchecked=$((unchecked + 1))
            ;;
    esac
}

# Checks the repositories named by `template_sets[$3]` of manifest "$1" against
# the template directory of that set. "$2" is the owner. The work happens in
# _canonical_drift_check_template_set_in with a scratch directory that is
# removed here, so no way out of it leaks the directory. Returns 0 always, a
# problem is a counted outcome. It shares the counters and rows of the sweep
# through dynamic scoping, see _canonical_drift_compare_remote.
_canonical_drift_check_template_set() {
    local scratch
    scratch="$(mktemp -d)" || {
        echo "::error::Could not create a scratch directory for template set $3, so its modules went unchecked."
        unchecked=$((unchecked + 1))
        return 0
    }

    _canonical_drift_check_template_set_in "$1" "$2" "$3" "${scratch}" || true
    rm -rf "${scratch}"
    return 0
}

_canonical_drift_check_template_set_in() {
    local manifest="$1"
    local owner="$2"
    local index="$3"
    local scratch="$4"

    local source_repo directory parameter_file
    source_repo="$(jq -r ".template_sets[${index}].source_repository" "${manifest}")"
    directory="$(jq -r ".template_sets[${index}].source_directory" "${manifest}")"
    parameter_file="$(jq -r ".template_sets[${index}].parameter_file" "${manifest}")"

    local tree rc
    rc=0
    tree="$(_canonical_drift_fetch "repos/${owner}/${source_repo}/git/trees/HEAD?recursive=1")" || rc=$?
    if [ "${rc}" -ne 0 ] || [ "$(jq -r '.truncated // false' <<<"${tree}" 2>/dev/null)" != "false" ]; then
        echo "::error::Could not list the template ${owner}/${source_repo}/${directory} completely, so its modules went unchecked."
        rows+="| ${source_repo} | \`${directory}\` | **unchecked** (template not listed) |"$'\n'
        unchecked=$((unchecked + 1))
        return 0
    fi

    # One line per template file: blob sha, then the path relative to the
    # directory as base64, because the path comes from another repository and
    # may hold any byte, a newline included.
    local template_files
    template_files="$(jq -r --arg dir "${directory}/" --argjson exclude "$(jq -c ".template_sets[${index}].exclude // []" "${manifest}")" '
        .tree[]
        | select(.type == "blob" and (.path | startswith($dir)))
        | (.path | ltrimstr($dir)) as $relative
        | select(($exclude | index($relative)) | not)
        | "\(.sha) \($relative | @base64)"' <<<"${tree}" 2>/dev/null)" || template_files=""

    if [ -z "${template_files}" ]; then
        echo "::error::The template ${owner}/${source_repo}/${directory} lists no files, so its modules went unchecked."
        rows+="| ${source_repo} | \`${directory}\` | **unchecked** (template is empty) |"$'\n'
        unchecked=$((unchecked + 1))
        return 0
    fi

    # The text of every PHP file is needed to render it per module, so it is
    # fetched once here. Other files compare by the template's own blob sha.
    local sha encoded relative shown body
    while read -r sha encoded; do
        relative="$(printf '%s' "${encoded}" | base64 -d)"
        [[ "${relative}" == *.php ]] || continue
        shown="$(_canonical_drift_label "${relative}")"

        # A failed fetch prints no body, so the decode below fails with it.
        body="$(_canonical_drift_fetch "repos/${owner}/${source_repo}/contents/${directory}/${relative}")" || true
        if ! mkdir -p "${scratch}/template/$(dirname "${relative}")" \
            || ! _canonical_drift_decode_content "${body}" "${scratch}/template/${relative}"; then
            echo "::error::Could not fetch the template file ${shown}, so its modules went unchecked."
            rows+="| ${source_repo} | \`${directory}/${shown}\` | **unchecked** (template file not fetched) |"$'\n'
            unchecked=$((unchecked + 1))
            return 0
        fi
    done <<<"${template_files}"

    local repo module_name module_ns canonical_sha rendered module_dir
    while IFS= read -r repo; do
        [ -n "${repo}" ] || continue

        module_dir="${scratch}/module-${repo}"
        mkdir -p "${module_dir}"

        rc=0
        body="$(_canonical_drift_fetch "repos/${owner}/${repo}/contents/${parameter_file}")" || rc=$?
        if [ "${rc}" -eq 1 ]; then
            echo "::error::${owner}/${repo}: ${parameter_file} is missing, so the files of ${source_repo}/${directory} cannot be compared."
            rows+="| ${repo} | \`${parameter_file}\` | **missing** |"$'\n'
            checked=$((checked + 1))
            failures=$((failures + 1))
            continue
        fi
        if ! _canonical_drift_decode_content "${body}" "${module_dir}/parameters"; then
            echo "::error::${owner}/${repo}: fetching ${parameter_file} failed, so its template files went unchecked."
            rows+="| ${repo} | \`${parameter_file}\` | **unchecked** (API error) |"$'\n'
            unchecked=$((unchecked + 1))
            continue
        fi

        module_name="$(_canonical_drift_module_parameter "${module_dir}/parameters" MODULE_NAME)" || module_name=""
        module_ns="$(_canonical_drift_module_parameter "${module_dir}/parameters" MODULE_NS)" || module_ns=""
        if [[ ! "${module_name}" =~ ^webtrees-[a-z0-9]+(-[a-z0-9]+)*$ ]] || [[ ! "${module_ns}" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
            echo "::error::${owner}/${repo}: ${parameter_file} does not hold a usable MODULE_NAME and MODULE_NS, so its template files went unchecked."
            rows+="| ${repo} | \`${parameter_file}\` | **unchecked** (MODULE_NAME or MODULE_NS unusable) |"$'\n'
            unchecked=$((unchecked + 1))
            continue
        fi

        while read -r sha encoded; do
            relative="$(printf '%s' "${encoded}" | base64 -d)"
            shown="$(_canonical_drift_label "${relative}")"
            canonical_sha="${sha}"

            if [[ "${relative}" == *.php ]]; then
                rendered="${module_dir}/rendered"
                sed -e "s/webtrees-<name>/${module_name}/g" \
                    -e "s/Webtrees\\\\ModuleName\\\\/Webtrees\\\\${module_ns}\\\\/g" \
                    "${scratch}/template/${relative}" >"${rendered}"

                if grep -q -e '<name>' -e 'ModuleName' "${rendered}"; then
                    echo "::error::The template file ${shown} holds a placeholder that is not rendered, so ${owner}/${repo} went unchecked for it."
                    rows+="| ${repo} | \`${shown}\` | **unchecked** (template placeholder) |"$'\n'
                    unchecked=$((unchecked + 1))
                    continue
                fi

                canonical_sha="$(git hash-object --stdin <"${rendered}")" || {
                    echo "::error::Could not hash the rendered ${shown}."
                    unchecked=$((unchecked + 1))
                    continue
                }
            fi

            _canonical_drift_compare_remote "${owner}" "${repo}" "${relative}" "${canonical_sha}" \
                "the template ${source_repo}/${directory}" "${shown}"
        done <<<"${template_files}"
    done < <(jq -r ".template_sets[${index}].repositories[]" "${manifest}")

    return 0
}

# Runs the sweep. Arguments: the manifest, the canonical root (this
# repository's checkout), the account that owns the repositories, and this
# repository's own name (the source of the canonical copies, so never
# checked against itself). Appends a Markdown report to $GITHUB_STEP_SUMMARY
# when it is set and the sweep runs to its end. An invalid manifest, a
# failed repository listing or a failed hash stops it early, reported by its
# ::error:: alone. Returns 1 when any file is missing, drifted, not a regular
# file or could not be checked, and when nothing at all was checked - the
# failure mode this sweep must not have is passing without having looked.
check_canonical_drift() {
    local manifest="$1"
    local canonical_root="$2"
    local owner="$3"
    local self_repo="$4"

    assert_canonical_manifest_valid "${manifest}" "${canonical_root}" || return 1

    local repos
    if ! repos="$(gh api --paginate "users/${owner}/repos?type=owner&per_page=100" --jq "${CANONICAL_DRIFT_REPO_FILTER}" 2>/dev/null)"; then
        echo "::error::Could not list the repositories of ${owner} - nothing was checked."
        return 1
    fi

    local count
    count="$(jq -r '.files | length' "${manifest}")"

    local checked=0 failures=0 unchecked=0
    local rows=""
    local repo i path applies canonical_sha rc

    while IFS= read -r repo; do
        [ -n "${repo}" ] || continue

        [ "${repo}" != "${self_repo}" ] || continue

        for ((i = 0; i < count; i++)); do
            path="$(jq -r ".files[${i}].path" "${manifest}")"
            applies="$(jq -r ".files[${i}].applies_when_present // \"\"" "${manifest}")"

            if [ -n "${applies}" ]; then
                rc=0
                _canonical_drift_fetch "repos/${owner}/${repo}/contents/${applies}" >/dev/null || rc=$?
                if [ "${rc}" -eq 1 ]; then
                    rows+="| ${repo} | \`${path}\` | not applicable (no \`${applies}\`) |"$'\n'
                    continue
                fi
                if [ "${rc}" -ne 0 ]; then
                    echo "::error::${owner}/${repo}: could not check whether ${applies} exists, so ${path} went unchecked."
                    rows+="| ${repo} | \`${path}\` | **unchecked** (API error) |"$'\n'
                    unchecked=$((unchecked + 1))
                    continue
                fi
            fi

            canonical_sha="$(canonical_blob_sha "${canonical_root}" "${path}")" || {
                echo "::error::Could not hash the canonical ${path}."
                return 1
            }

            _canonical_drift_compare_remote "${owner}" "${repo}" "${path}" "${canonical_sha}" \
                "the canonical copy in ${owner}/${self_repo}" "${path}"
        done
    done <<<"${repos}"

    local set_count compared_against="${owner}/${self_repo}"
    set_count="$(jq -r '(.template_sets // []) | length' "${manifest}")"
    for ((i = 0; i < set_count; i++)); do
        compared_against+=" and $(jq -r ".template_sets[${i}] | \"${owner}/\" + .source_repository + \"/\" + .source_directory" "${manifest}")"
        _canonical_drift_check_template_set "${manifest}" "${owner}" "${i}"
    done

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "## Canonical-file drift"
            echo
            echo "Compared against \`${compared_against}\` - ${checked} file(s) checked, ${failures} failed (drifted, missing or not a regular file), ${unchecked} unchecked."
            echo
            if [ -n "${rows}" ]; then
                echo "| Repository | File | Result |"
                echo "| --- | --- | --- |"
                printf '%s' "${rows}"
            fi
        } >>"${GITHUB_STEP_SUMMARY}"
    fi

    if [ "${checked}" -eq 0 ] && [ "${unchecked}" -eq 0 ]; then
        echo "::error::No repository of ${owner} was in scope for any canonical file - the sweep checked nothing."
        return 1
    fi

    if [ "${failures}" -gt 0 ] || [ "${unchecked}" -gt 0 ]; then
        echo "::error::${failures} canonical file(s) failed (drifted, missing or not a regular file), ${unchecked} unchecked - see the job summary."
        return 1
    fi

    echo "  ✔ ${checked} canonical file(s) across ${owner}'s repositories pass against ${compared_against}"
    return 0
}
