#!/usr/bin/env bash
# Sourced by renovate-dry-run.yml's "Evaluate the report" step and by
# .github/scripts/tests/test-renovate-dry-run-report.sh, so the workflow and its
# test drive the same file rather than two copies that can drift apart.
#
# The report is the JSON file that a Renovate dry run writes: the repositories
# it read, for each the package files by manager, for each package file its
# dependencies, and for each dependency the updates Renovate would propose.
# Only the github-actions manager is read, because that is where the calls of
# the shared workflows are.

SHARED_WORKFLOWS_DEP_NAME="magicsunday/.github"

# Fails unless "$1" names a repository of this account, as magicsunday/name. The
# value reaches Renovate as the repository to read, so a typo, another owner or
# a value with a path, a blank or a shell metacharacter stops the run here.
renovate_dry_run_check_repository() {
    if ! [[ "$1" =~ ^magicsunday/[A-Za-z0-9._-]+$ ]]; then
        echo "::error::The repository input must read magicsunday/name."
        return 1
    fi
}

# Prints the number of calls of the dependency "$2" that the github-actions
# manager found in the report "$1". Prints nothing and fails on a report that
# cannot be read as JSON.
renovate_report_dependency_count() {
    jq -e --arg name "$2" \
        '[.repositories[]?.packageFiles["github-actions"][]?.deps[]? | select(.depName == $name)] | length' "$1"
}

# Prints one line for every update that the report proposes for a dependency of
# the github-actions manager: the dependency, the current value, the update type
# and the new value, separated by blanks.
renovate_report_updates() {
    jq -r \
        '.repositories[]?.packageFiles["github-actions"][]?.deps[]?
         | . as $dep
         | ($dep.updates // [])[]
         | "\($dep.depName) \($dep.currentValue) \(.updateType) \(.newValue // "")" | rtrimstr(" ")' "$1"
}

# Checks the report "$1" against the policy of the shared Renovate preset: the
# shared workflows are called with the @main ref, so Renovate proposes no update
# for them, neither a pin nor a newer ref. Fails when the report cannot be read,
# when it never saw a call of the shared workflows (the run then proves nothing
# about them, a report without a repository included) and when it proposes any
# update for them. Prints the reason on failure and a one-line result on success.
renovate_report_check_shared_workflows() {
    local report="$1" calls shared_updates

    if [ ! -s "${report}" ]; then
        echo "::error::The report is missing or empty, so the run proves nothing."
        return 1
    fi

    if ! jq -e 'type == "object"' "${report}" >/dev/null 2>&1; then
        echo "::error::The report is not a JSON object, so the run proves nothing."
        return 1
    fi

    calls="$(renovate_report_dependency_count "${report}" "${SHARED_WORKFLOWS_DEP_NAME}")" || return 1
    if [ "${calls}" -eq 0 ]; then
        echo "::error::The report holds no call of ${SHARED_WORKFLOWS_DEP_NAME} in the github-actions manager, so the run proves nothing about the shared workflows."
        return 1
    fi

    shared_updates="$(renovate_report_updates "${report}" | grep -F -e "${SHARED_WORKFLOWS_DEP_NAME} " || true)"
    if [ -n "${shared_updates}" ]; then
        echo "::error::Renovate proposes updates for the shared workflows, which the preset keeps unpinned:"
        echo "${shared_updates}"
        return 1
    fi

    echo "The shared workflows were seen in ${calls} calls and receive no update."
}
