#!/usr/bin/env bash
# Sourced by auto-merge-deps.yml's "Classify the update type" step and by
# .github/scripts/tests/test-auto-merge-update-type.sh, so the workflow and
# its test drive the same file rather than two copies that can drift apart.
#
# Dependabot reports the new version of a git-pinned dependency
# (`github:owner/repo#X.Y.Z`) as a commit hash, from which no update type can
# be read. A group with such a pin is classified here from the tag in the
# package.json patch instead.

_AUTO_MERGE_HASH_PATTERN='^[0-9a-f]{40}$'
_AUTO_MERGE_UNIT_SEPARATOR=$'\x1f'
# A files answer of at least this many files is treated as possibly cut off.
_AUTO_MERGE_FILES_LIMIT=3000

# Prints the source and the tag of dependency "$2" as `source#tag` on the side
# "$3" of the package.json patch "$1" (`-` for the old line, `+` for the new
# one). Unchanged lines belong to both sides, so the key of a declaration whose
# value sits on the next line counts as a declaration, and such a pin has no
# value to read. Prints nothing unless the quoted key occurs exactly once on
# that side, and then only the value of that key counts. A name that occurs in
# several sections, or twice on one line, or a pin that follows a branch or
# carries no numeric tag cannot be classified.
_pin_tag() {
    local patch="$1"
    local name="$2"
    local side="$3"

    printf '%s\n' "${patch}" | sed -E 's/"[[:space:]]+:/":/g' | awk -v side="${side}" -v key="\"${name}\":" '
        substr($0, 1, 1) == side || substr($0, 1, 1) == " " {
            rest = $0
            while ((position = index(rest, key)) > 0) {
                occurrences++
                rest = substr(rest, position + length(key))
                if (occurrences == 1) {
                    value = rest
                }
            }
        }
        END { if (occurrences == 1) { print value } }
    ' | sed -nE 's/^[[:space:]]*"([^"#]*)#v?([0-9]{1,9}(\.[0-9]{1,9}){0,2})".*/\1#\2/p'
}

# Prints the update type that the move from tag "$1" to tag "$2" amounts to.
# Prints `unknown` when a tag is missing, when both tags are equal as numbers
# and when the new tag is the lower one, because a downgrade is no bump.
_tag_update_type() {
    local old_tag="$1"
    local new_tag="$2"
    local old_major old_minor old_patch new_major new_minor new_patch
    local bump difference

    if [ -z "${old_tag}" ] || [ -z "${new_tag}" ]; then
        echo "unknown"
        return 0
    fi

    IFS=. read -r old_major old_minor old_patch <<<"${old_tag}"
    IFS=. read -r new_major new_minor new_patch <<<"${new_tag}"

    # The base prefix keeps a leading zero from reading as octal. The tag
    # pattern bounds the length of a component, so this cannot overflow.
    old_major=$((10#${old_major}))
    old_minor=$((10#${old_minor:-0}))
    old_patch=$((10#${old_patch:-0}))
    new_major=$((10#${new_major}))
    new_minor=$((10#${new_minor:-0}))
    new_patch=$((10#${new_patch:-0}))

    if [ "${new_major}" -ne "${old_major}" ]; then
        bump="major"
        difference=$((new_major - old_major))
    elif [ "${new_minor}" -ne "${old_minor}" ]; then
        bump="minor"
        difference=$((new_minor - old_minor))
    elif [ "${new_patch}" -ne "${old_patch}" ]; then
        bump="patch"
        difference=$((new_patch - old_patch))
    else
        echo "unknown"
        return 0
    fi

    if [ "${difference}" -lt 0 ]; then
        echo "unknown"
        return 0
    fi

    echo "version-update:semver-${bump}"
}

# Ranks an update type for picking the highest one of a group. Everything
# that is not a semver type, `unknown` included, ranks highest so that it
# holds the pull request.
_update_type_rank() {
    case "$1" in
        version-update:semver-patch) echo 1 ;;
        version-update:semver-minor) echo 2 ;;
        version-update:semver-major) echo 3 ;;
        *) echo 4 ;;
    esac
}

# Prints the update type of a whole Dependabot group.
#
#   $1  the updated-dependencies-json that comes with the group
#   $2  the package.json patch of the pull request (read only when needed)
#   $3  the update type that comes with the group
#
# Without a dependency whose new version is a commit hash, the type of the
# action is printed unchanged. Otherwise the highest type of the group is
# printed, with the type of each git pin taken from its tag. A dependency
# that cannot be classified makes the result `unknown`.
effective_update_type() {
    local dependencies_json="$1"
    local patch="$2"
    local group_type="$3"
    local pins repeated rows
    local name update_type new_version dependency_type old_pin new_pin
    local highest="version-update:semver-patch"

    # A malformed list answers `unknown` right here, so the filters below never
    # see one and the caller never gets an empty answer.
    jq -e 'type == "array" and all(.[]; type == "object")' >/dev/null 2>&1 <<<"${dependencies_json}" \
        || { echo "unknown"; return 0; }

    pins="$(jq -r --arg pattern "${_AUTO_MERGE_HASH_PATTERN}" \
        '[.[] | select((.newVersion | type == "string") and (.newVersion | test($pattern)))] | length' \
        <<<"${dependencies_json}")"

    if [ "${pins}" = "0" ]; then
        echo "${group_type}"
        return 0
    fi

    # Two entries of one name share one manifest change, so the second entry
    # has no tag pair of its own and the group cannot be classified.
    repeated="$(jq -r --arg pattern "${_AUTO_MERGE_HASH_PATTERN}" \
        '[.[] | select((.newVersion | type == "string") and (.newVersion | test($pattern))) | (.dependencyName // "")]
            | length - (unique | length)' \
        <<<"${dependencies_json}")"

    if [ "${repeated}" != "0" ]; then
        echo "unknown"
        return 0
    fi

    rows="$(jq -r --arg separator "${_AUTO_MERGE_UNIT_SEPARATOR}" \
        '.[] | [(.dependencyName // ""), (.updateType // ""), (.newVersion // "")] | map(tostring) | join($separator)' \
        <<<"${dependencies_json}")"

    while IFS="${_AUTO_MERGE_UNIT_SEPARATOR}" read -r name update_type new_version; do
        if [[ "${new_version}" =~ ${_AUTO_MERGE_HASH_PATTERN} ]]; then
            old_pin="$(_pin_tag "${patch}" "${name}" "-")"
            new_pin="$(_pin_tag "${patch}" "${name}" "+")"
            if [ "${old_pin%%#*}" != "${new_pin%%#*}" ]; then
                dependency_type="unknown"
            else
                dependency_type="$(_tag_update_type "${old_pin#*#}" "${new_pin#*#}")"
            fi
        else
            dependency_type="${update_type:-unknown}"
        fi

        if [ "$(_update_type_rank "${dependency_type}")" -gt "$(_update_type_rank "${highest}")" ]; then
            highest="${dependency_type}"
        fi
    done <<<"${rows}"

    case "${highest}" in
        version-update:semver-patch | version-update:semver-minor | version-update:semver-major) echo "${highest}" ;;
        *) echo "unknown" ;;
    esac
}

# Prints the patches of the package.json files of a pull request, out of the
# pages of the files API ("$1", an array of pages). Prints nothing when a
# package.json entry has no patch of type string, when the answer reached the
# limit of the files API and may be cut off, or when the pages are malformed.
# Evidence of one manifest must not stand in for a manifest that cannot be
# inspected, and an empty answer leaves every pin unclassified.
package_json_patches() {
    jq -r --argjson limit "${_AUTO_MERGE_FILES_LIMIT}" 'add // []
        | if length >= $limit then empty else
            [.[] | select((.filename | split("/") | last) == "package.json")]
            | if any(.[]; (.patch | type) != "string") then empty else .[].patch end
          end' \
        <<<"$1" 2>/dev/null || true
}

# Succeeds when the dependency list "$1" holds a dependency whose new version is
# a commit hash, which is the only case that needs the patches of the pull
# request.
has_git_pin() {
    jq -e --arg pattern "${_AUTO_MERGE_HASH_PATTERN}" \
        'type == "array" and any(.[]; type == "object" and (.newVersion | type == "string") and (.newVersion | test($pattern)))' \
        >/dev/null 2>&1 <<<"$1" || return 1
}
