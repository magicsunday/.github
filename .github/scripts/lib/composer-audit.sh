#!/usr/bin/env bash
# Sourced by composer-audit.yml and by
# .github/scripts/tests/test-composer-audit.sh, so the workflow and its test
# drive the same file rather than two copies that can drift apart.

# Audits the Composer dependencies of the repository in the current directory,
# or of the folder named by the optional argument, and returns the exit status
# of the audit, so a vulnerable dependency fails the caller. The folder is
# relative to the current directory, so a repository that keeps its manifests
# in a subfolder audits each of them with one call. Only a plain folder name is
# supported, written with letters, digits and the characters . _ - and /, and
# starting with none of - and /. Everything else is refused, and so is a
# parent segment, a name that is no directory, a link that leads out of the
# current directory, a path below it that leaves the supported characters, and a
# folder without the manifest file, before any Composer command runs. The audit
# settings of the manifest file apply unchanged, because every
# call below is a plain Composer command. This function adds no ignore handling
# of its own. Both audit calls run without the scripts and plugins of the
# repository.
#
# The optional second argument names the Composer manifest in that folder, and
# the default is composer.json. Only a plain file name is supported, written
# with letters, digits and the characters . _ and -, starting with a letter, a
# digit or an underscore and ending in .json. Everything else is refused before
# any Composer command runs. Every Composer command reads that file through the
# COMPOSER setting, and its lock file is the file name with the extension .lock.
# A named file that does not exist fails the check, because a typo would
# otherwise audit nothing.
#
# In the cases below, composer.json and composer.lock stand for the named
# manifest and its lock file when a manifest is named.
#
# - No composer.json at the repository root and no manifest named: nothing to
#   audit, the check passes and says so, so every repository can carry the same
#   job.
# - A committed composer.lock: audits exactly that lock file. The lock file
#   must be a regular, readable, non-empty file. An empty file, a symlink or
#   an unreadable file fails, so a broken lock file never turns into a quiet
#   fresh resolution of whatever the constraints allow today.
# - No composer.lock: resolves the declared constraints fresh, which is what a
#   consumer install does, and audits the result. The resolution writes a lock
#   file into the workspace without installing a package and without running
#   a script or a plugin of the repository. Platform requirements are ignored
#   during the resolution, because nothing is installed, so the resolution
#   reflects the declared constraints and not the PHP of the runner. Without
#   that, a repository that requires a newer PHP than the runner provides fails
#   before the audit runs. The flag can pick newer versions than a consumer on
#   an older PHP would get.
composer_audit_run() {
    local directory="${1:-.}" manifest="${2:-composer.json}"

    _composer_audit_check_manifest_name "${manifest}" || return 1

    if [ "${directory}" = "." ]; then
        _composer_audit_here "this repository" root "${manifest}"
        return
    fi

    _composer_audit_check_folder_name "${directory}" || return 1

    # A subshell, so the caller keeps its own working directory.
    (_composer_audit_in_folder "${directory}" "${manifest}")
}

# The letters and digits of a supported folder or manifest file name, written
# out one by one, because a range such as a-z also matches accented letters in
# some locales.
_COMPOSER_AUDIT_FOLDER_CHARACTERS='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

# Checks the file name "$1" of the manifest. It prints an error annotation
# without the name and fails when the name is not a plain file name that ends in
# .json.
_composer_audit_check_manifest_name() {
    local manifest="$1"

    if [[ ! "${manifest}" =~ ^[${_COMPOSER_AUDIT_FOLDER_CHARACTERS}_][${_COMPOSER_AUDIT_FOLDER_CHARACTERS}._-]*\.json$ ]]; then
        echo "::error::The manifest file to audit may only use letters, digits and the characters . _ and -, must start with a letter, a digit or an underscore and must end in .json."
        return 1
    fi
}

# Checks the name of folder "$1" before it is looked at on disk. It prints an
# error annotation without the folder name, so a name with a line break cannot
# reach the log as a workflow command, and fails when the name is not a plain
# relative path to a directory.
_composer_audit_check_folder_name() {
    local directory="$1"

    if [[ ! "${directory}" =~ ^[${_COMPOSER_AUDIT_FOLDER_CHARACTERS}._][${_COMPOSER_AUDIT_FOLDER_CHARACTERS}._/-]*$ ]]; then
        echo "::error::The folder to audit may only use letters, digits and the characters . _ - and /, and must start with a letter, a digit, a dot or an underscore."
        return 1
    fi

    case "/${directory}/" in
        */../*)
            echo "::error::The folder to audit must not hold a parent segment."
            return 1
            ;;
    esac

    if [ ! -d "${directory}" ]; then
        echo "::error::The folder to audit is not a directory of this repository."
        return 1
    fi
}

# Enters folder "$1" and audits it. It runs in a subshell of the caller. The
# physical path is read from `PWD` and not through command substitution, which
# strips a line break at the end of a directory name. A link can lead to a
# directory below the repository with a name outside the supported characters,
# and such a path is refused like one that leads out of the repository. "$2" is
# the file name of the manifest.
_composer_audit_in_folder() {
    local directory="$1" manifest="$2" workspace below

    cd -P . 2> /dev/null || {
        echo "::error::The current directory cannot be resolved."
        return 1
    }
    workspace="${PWD}"

    # The leading ./ keeps `cd` from searching CDPATH, which would resolve the
    # folder in another directory than the repository.
    cd -P "./${directory}" 2> /dev/null || {
        echo "::error::The folder to audit cannot be entered."
        return 1
    }

    case "${PWD}/" in
        "${workspace}"/*) ;;
        *)
            echo "::error::The folder to audit leads out of the repository."
            return 1
            ;;
    esac

    below="${PWD#"${workspace}"}"
    if [[ ! "${below}" =~ ^[${_COMPOSER_AUDIT_FOLDER_CHARACTERS}._/-]*$ ]]; then
        echo "::error::The folder to audit leads to a path with a name outside the supported characters."
        return 1
    fi

    _composer_audit_here "${directory}" folder "${manifest}"
}

# The audit of the current directory. "$1" names it in the notice for a
# directory without the manifest file, and "$2" is `root` for the repository root,
# where that is no error, or `folder` for a folder that the caller named, where
# it is one, because a folder name with a typo would otherwise audit nothing.
# "$3" is the file name of the manifest. A manifest with another name than
# composer.json that is missing is an error in both cases, for the same reason.
_composer_audit_here() {
    local manifest="$3" lock="${3%.json}.lock"

    if [ ! -e "${manifest}" ] && [ ! -L "${manifest}" ]; then
        if [ "${manifest}" != "composer.json" ]; then
            echo "No ${manifest} in $1."
            echo "::error::The folder to audit holds no manifest file of that name. Fix the file name, or leave it out to audit composer.json."
            return 1
        fi
        if [ "$2" = "folder" ]; then
            echo "No composer.json in the folder $1."
            echo "::error::The folder to audit holds no composer.json. Fix the folder name, or leave the folder out to audit the repository root."
            return 1
        fi
        echo "No composer.json in $1, so there is nothing to audit."
        return 0
    fi

    if [ -e "${lock}" ] || [ -L "${lock}" ]; then
        if [ -L "${lock}" ] || [ ! -f "${lock}" ] || [ ! -s "${lock}" ] || [ ! -r "${lock}" ]; then
            echo "::error::${lock} is not a regular, readable, non-empty file. Commit a valid lock file or remove it so the dependencies are resolved fresh."
            return 1
        fi

        echo "Auditing the committed ${lock}."
        COMPOSER="${manifest}" composer audit --locked --no-scripts --no-plugins --no-interaction
        return
    fi

    echo "No ${lock} is committed, so the constraints are resolved fresh."
    COMPOSER="${manifest}" composer update --no-install --no-scripts --no-plugins --no-interaction --no-progress \
        --ignore-platform-reqs || return
    COMPOSER="${manifest}" composer audit --locked --no-scripts --no-plugins --no-interaction
}
