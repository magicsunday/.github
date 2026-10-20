#!/usr/bin/env bash
# Sourced by auto-merge-deps.yml's "Classify the update type" step and by
# .github/scripts/tests/test-auto-merge-update-type.sh, so the workflow and
# its test drive the same file rather than two copies that can drift apart.
#
# Dependabot reports the new version of a git-pinned dependency
# (`github:owner/repo#X.Y.Z`) as a commit hash, and the metadata action
# compares the first dot-separated segment of the old version with that hash,
# so every bump of such a pin counts as a major one. The group-wide update
# type is the highest one of the group, so one git pin makes the whole group
# a major update. This file classifies such a group from the tag in the
# package.json patch instead.

readonly _AUTO_MERGE_HASH_PATTERN='^[0-9a-f]{40}$'
readonly _AUTO_MERGE_UNIT_SEPARATOR=$'\x1f'

# Prints the tag of the package.json line for dependency "$2" on the side "$3"
# of the patch "$1" (`-` for the old line, `+` for the new one). Prints
# nothing unless exactly one such line carries a tag of up to three numeric
# components, because a name that occurs in several sections or a pin that
# follows a branch cannot be classified.
_pin_tag() {
    local patch="$1"
    local name="$2"
    local side="$3"
    local lines

    lines="$(printf '%s\n' "${patch}" | awk -v side="${side}" -v key="\"${name}\":" \
        'substr($0, 1, 1) == side && index($0, key) { print }')"

    if [ -z "${lines}" ] || [ "$(printf '%s\n' "${lines}" | wc -l)" -ne 1 ]; then
        return 0
    fi

    printf '%s\n' "${lines}" | sed -nE 's/.*#v?([0-9]+(\.[0-9]+){0,2})".*/\1/p'
}

# Prints the update type that the move from tag "$1" to tag "$2" amounts to,
# or `unknown` when a tag is missing or both are equal.
_tag_update_type() {
    local old_tag="$1"
    local new_tag="$2"
    local old_major old_minor old_patch new_major new_minor new_patch

    if [ -z "${old_tag}" ] || [ -z "${new_tag}" ] || [ "${old_tag}" = "${new_tag}" ]; then
        echo "unknown"
        return 0
    fi

    IFS=. read -r old_major old_minor old_patch <<<"${old_tag}"
    IFS=. read -r new_major new_minor new_patch <<<"${new_tag}"

    if [ "${old_major}" != "${new_major}" ]; then
        echo "version-update:semver-major"
    elif [ "${old_minor:-0}" != "${new_minor:-0}" ]; then
        echo "version-update:semver-minor"
    elif [ "${old_patch:-0}" != "${new_patch:-0}" ]; then
        echo "version-update:semver-patch"
    else
        echo "unknown"
    fi
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
#   $1  updated-dependencies-json of the metadata action
#   $2  the package.json patch of the pull request (read only when needed)
#   $3  the group update type that the metadata action reported
#
# Without a dependency whose new version is a commit hash, the type of the
# action is printed unchanged. Otherwise the highest type of the group is
# printed, with the type of each git pin taken from its tag. A dependency
# that cannot be classified makes the result `unknown`.
effective_update_type() {
    local dependencies_json="$1"
    local patch="$2"
    local group_type="$3"
    local pins
    local name update_type new_version dependency_type old_tag new_tag
    local highest="version-update:semver-patch"

    pins="$(jq -r --arg pattern "${_AUTO_MERGE_HASH_PATTERN}" \
        '[.[] | select((.newVersion // "") | test($pattern))] | length' <<<"${dependencies_json}")"

    if [ "${pins}" = "0" ]; then
        echo "${group_type}"
        return 0
    fi

    while IFS="${_AUTO_MERGE_UNIT_SEPARATOR}" read -r name update_type new_version; do
        if [[ "${new_version}" =~ ${_AUTO_MERGE_HASH_PATTERN} ]]; then
            old_tag="$(_pin_tag "${patch}" "${name}" "-")"
            new_tag="$(_pin_tag "${patch}" "${name}" "+")"
            dependency_type="$(_tag_update_type "${old_tag}" "${new_tag}")"
        else
            dependency_type="${update_type:-unknown}"
        fi

        if [ "$(_update_type_rank "${dependency_type}")" -gt "$(_update_type_rank "${highest}")" ]; then
            highest="${dependency_type}"
        fi
    done < <(jq -r --arg separator "${_AUTO_MERGE_UNIT_SEPARATOR}" \
        '.[] | [.dependencyName, (.updateType // ""), (.newVersion // "")] | join($separator)' <<<"${dependencies_json}")

    case "${highest}" in
        version-update:semver-patch | version-update:semver-minor | version-update:semver-major) echo "${highest}" ;;
        *) echo "unknown" ;;
    esac
}
