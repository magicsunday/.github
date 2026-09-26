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
# compares each canonical file by git blob hash, which is one contents-API
# call per file and needs no download: identical bytes give an identical blob
# hash. It reports and never writes - opening a pull request per drifted
# repository is the obvious follow-up once the canonical set is stable.
#
# Which files are canonical is declared in .github/canonical-files.json, and
# the canonical CONTENT of each is this repository's own copy at the same
# path. The manifest therefore only names paths; there is no second copy of
# the content to fall out of step with the file it describes, and
# assert_canonical_manifest_valid() fails the run if a listed path does not
# exist here.
#
# Coverage limit, stated rather than hidden: the sweep runs on this
# repository's own GITHUB_TOKEN, which can read another repository only while
# that repository is public. A private repository is not listed and not
# checked.
#
# No lib-to-lib `source` here on purpose: every value this file prints into
# an annotation is either a manifest path or a repository name, and both are
# validated against a fixed character set before use (a repository name that
# fails it is reported as unchecked, never echoed raw), so there is nothing
# annotation-sanitize.sh would need to escape.

# Per page of `GET /users/{owner}/repos`: the repositories worth checking.
# Archived repositories are frozen and forks mirror an upstream, so neither is
# expected to carry this account's canonical files (issue #38's open question
# on membership, settled here).
readonly CANONICAL_DRIFT_REPO_FILTER='.[] | select((.archived | not) and (.fork | not)) | .name'

# The only shapes a manifest path or a repository name may take. GitHub
# restricts repository names to this set already; enforcing it here keeps an
# unexpected API value out of annotations and out of the request path.
readonly CANONICAL_DRIFT_NAME_RE='^[A-Za-z0-9._-]+$'
readonly CANONICAL_DRIFT_PATH_RE='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

# Prints the git blob hash of file "$1" as stored - `--no-filters` so a
# .gitattributes line-ending rule in the checkout cannot make the local hash
# differ from the blob the contents API reports for the same bytes.
canonical_blob_sha() {
    git hash-object --no-filters -- "$1"
}

# Validates manifest "$1" against canonical root "$2": a non-empty `files`
# array, every `path` (and `applies_when_present`, when given) of the allowed
# shape and free of `..` segments, every `path` a regular file under the root,
# and every `exempt` entry a valid repository name. Returns 1 with an
# ::error:: per problem.
assert_canonical_manifest_valid() {
    local manifest="$1"
    local canonical_root="$2"
    local problems=0
    local count path applies exempt_names name

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

        if ! [[ "${path}" =~ ${CANONICAL_DRIFT_PATH_RE} ]] || [[ "/${path}/" == */../* ]]; then
            echo "::error::${manifest}: files[${i}].path is not a plain repository-relative path."
            problems=$((problems + 1))
            continue
        fi

        if [ ! -f "${canonical_root}/${path}" ] || [ -L "${canonical_root}/${path}" ]; then
            echo "::error::${manifest}: ${path} is not a regular file in this repository, so it has no canonical content to compare against."
            problems=$((problems + 1))
        fi

        applies="$(jq -r ".files[${i}].applies_when_present // \"\"" "${manifest}")"
        if [ -n "${applies}" ] && { ! [[ "${applies}" =~ ${CANONICAL_DRIFT_PATH_RE} ]] || [[ "/${applies}/" == */../* ]]; }; then
            echo "::error::${manifest}: files[${i}].applies_when_present is not a plain repository-relative path."
            problems=$((problems + 1))
        fi

        if ! jq -e ".files[${i}].exempt // [] | type == \"array\" and all(type == \"string\")" "${manifest}" >/dev/null 2>&1; then
            echo "::error::${manifest}: files[${i}].exempt must be an array of repository names."
            problems=$((problems + 1))
            continue
        fi
        exempt_names="$(jq -r ".files[${i}].exempt // [] | .[]" "${manifest}")"

        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            if ! [[ "${name}" =~ ${CANONICAL_DRIFT_NAME_RE} ]]; then
                echo "::error::${manifest}: files[${i}].exempt holds an invalid repository name."
                problems=$((problems + 1))
            fi
        done <<<"${exempt_names}"
    done

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
# `not-a-file` (a directory listing, a symlink, a submodule - anything the
# canonical file cannot be), and returns 0 only for `ok`.
classify_canonical_entry() {
    local body="$1"
    local canonical_sha="$2"
    local kind remote_sha

    kind="$(jq -r 'if type == "object" then (.type // "") else "listing" end' <<<"${body}" 2>/dev/null)" || kind=""

    if [ "${kind}" != "file" ]; then
        printf 'not-a-file'
        return 1
    fi

    remote_sha="$(jq -r '.sha // ""' <<<"${body}" 2>/dev/null)" || remote_sha=""

    if [ -n "${remote_sha}" ] && [ "${remote_sha}" = "${canonical_sha}" ]; then
        printf 'ok'
        return 0
    fi

    printf 'drifted'
    return 1
}

# Runs the sweep. Arguments: the manifest, the canonical root (this
# repository's checkout), the account that owns the repositories, and this
# repository's own name (the source of the canonical copies, so never
# checked against itself). Appends a Markdown report to $GITHUB_STEP_SUMMARY
# when it is set. Returns 1 when any file is missing, drifted or could not be
# checked, and when nothing at all was checked - the failure mode this sweep
# must not have is passing without having looked.
check_canonical_drift() {
    local manifest="$1"
    local canonical_root="$2"
    local owner="$3"
    local self_repo="$4"

    assert_canonical_manifest_valid "${manifest}" "${canonical_root}" || return 1

    if ! [[ "${owner}" =~ ${CANONICAL_DRIFT_NAME_RE} ]]; then
        echo "::error::The owner name is not a valid account name."
        return 1
    fi

    local repos
    if ! repos="$(gh api --paginate "users/${owner}/repos?type=owner&per_page=100" --jq "${CANONICAL_DRIFT_REPO_FILTER}" 2>/dev/null)"; then
        echo "::error::Could not list the repositories of ${owner} - nothing was checked."
        return 1
    fi

    local count
    count="$(jq -r '.files | length' "${manifest}")"

    local checked=0 failures=0 unchecked=0
    local rows=""
    local repo i path applies exempt canonical_sha body rc status

    while IFS= read -r repo; do
        [ -n "${repo}" ] || continue

        if ! [[ "${repo}" =~ ${CANONICAL_DRIFT_NAME_RE} ]]; then
            echo "::error::The repository listing returned a name outside the allowed character set - that entry was not checked."
            unchecked=$((unchecked + 1))
            continue
        fi

        [ "${repo}" != "${self_repo}" ] || continue

        for ((i = 0; i < count; i++)); do
            path="$(jq -r ".files[${i}].path" "${manifest}")"
            applies="$(jq -r ".files[${i}].applies_when_present // \"\"" "${manifest}")"

            if jq -e --arg repo "${repo}" ".files[${i}].exempt // [] | index(\$repo)" "${manifest}" >/dev/null 2>&1; then
                rows+="| ${repo} | \`${path}\` | exempt |"$'\n'
                continue
            fi

            if [ -n "${applies}" ]; then
                _canonical_drift_fetch "repos/${owner}/${repo}/contents/${applies}" >/dev/null
                rc=$?
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

            canonical_sha="$(canonical_blob_sha "${canonical_root}/${path}")" || {
                echo "::error::Could not hash the canonical ${path}."
                return 1
            }

            body="$(_canonical_drift_fetch "repos/${owner}/${repo}/contents/${path}")"
            rc=$?
            checked=$((checked + 1))

            case "${rc}" in
                0)
                    status="$(classify_canonical_entry "${body}" "${canonical_sha}")"
                    case "${status}" in
                        ok)
                            rows+="| ${repo} | \`${path}\` | ok |"$'\n'
                            ;;
                        drifted)
                            echo "::error::${owner}/${repo}: ${path} differs from the canonical copy in ${owner}/${self_repo}."
                            rows+="| ${repo} | \`${path}\` | **drifted** |"$'\n'
                            failures=$((failures + 1))
                            ;;
                        *)
                            echo "::error::${owner}/${repo}: ${path} exists but is not a regular file."
                            rows+="| ${repo} | \`${path}\` | **not a regular file** |"$'\n'
                            failures=$((failures + 1))
                            ;;
                    esac
                    ;;
                1)
                    echo "::error::${owner}/${repo}: ${path} is missing."
                    rows+="| ${repo} | \`${path}\` | **missing** |"$'\n'
                    failures=$((failures + 1))
                    ;;
                *)
                    echo "::error::${owner}/${repo}: fetching ${path} failed, so it went unchecked."
                    rows+="| ${repo} | \`${path}\` | **unchecked** (API error) |"$'\n'
                    checked=$((checked - 1))
                    unchecked=$((unchecked + 1))
                    ;;
            esac
        done
    done <<<"${repos}"

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "## Canonical-file drift"
            echo
            echo "Compared against \`${owner}/${self_repo}\` - ${checked} file(s) checked, ${failures} drifted or missing, ${unchecked} unchecked."
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
        echo "::error::${failures} canonical file(s) drifted or missing, ${unchecked} unchecked - see the job summary."
        return 1
    fi

    echo "  ✔ ${checked} canonical file(s) across ${owner}'s repositories match ${owner}/${self_repo}"
    return 0
}
