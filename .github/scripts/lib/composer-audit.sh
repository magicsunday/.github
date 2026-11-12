#!/usr/bin/env bash
# Sourced by composer-audit.yml and by
# .github/scripts/tests/test-composer-audit.sh, so the workflow and its test
# drive the same file rather than two copies that can drift apart.

# Audits the Composer dependencies of the repository in the current directory
# and returns the exit status of the audit, so a vulnerable dependency fails
# the caller. The audit settings of the repository's own composer.json apply
# unchanged, because every call below is a plain Composer command. This
# function adds no ignore handling of its own.
#
# - No composer.json: nothing to audit, the check passes and says so.
# - A committed composer.lock: audits exactly that lock file. The lock file
#   must be a regular, readable, non-empty file. An empty file, a symlink or
#   an unreadable file fails, so a broken lock file never turns into a quiet
#   fresh resolution of whatever the constraints allow today.
# - No composer.lock: resolves the declared constraints fresh, which is what a
#   consumer install does, and audits the result. The resolution writes a lock
#   file into the workspace without installing a package and without running
#   a script or a plugin of the repository. Platform requirements are ignored
#   during the resolution, because nothing is installed and the advisories do
#   not depend on the platform of the runner. Without that, a repository that
#   requires a newer PHP than the runner provides fails before the audit runs.
composer_audit_run() {
    if [ ! -e composer.json ] && [ ! -L composer.json ]; then
        echo "No composer.json in this repository, so there is nothing to audit."
        return 0
    fi

    if [ -e composer.lock ] || [ -L composer.lock ]; then
        if [ -L composer.lock ] || [ ! -f composer.lock ] || [ ! -s composer.lock ] || [ ! -r composer.lock ]; then
            echo "::error::composer.lock is not a regular, readable, non-empty file. Commit a valid lock file or remove it so the dependencies are resolved fresh."
            return 1
        fi

        echo "Auditing the committed composer.lock."
        composer audit --locked --no-interaction
        return
    fi

    echo "No composer.lock is committed, so the constraints are resolved fresh."
    composer update --no-install --no-scripts --no-plugins --no-interaction --no-progress \
        --ignore-platform-reqs || return
    composer audit --locked --no-interaction
}
