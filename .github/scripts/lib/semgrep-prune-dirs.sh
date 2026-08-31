#!/usr/bin/env bash
# Single source of truth for the directories excluded from Semgrep scanning
# at any depth. Both the Run Semgrep step's --exclude flags
# (code-scanning.yml) and find_semgrepignore_files()'s prune clause
# (semgrepignore-guard.sh) read this array, so a single edit here updates
# both call sites instead of two hand-maintained copies that could drift
# apart again (issue #79, deferred from issue #48).
#
# `.git` is deliberately NOT in this array — see semgrepignore-guard.sh's own
# comment for why it is pruned by its own separate literal instead. `*.min.js`
# is also not here: it is a file-suffix glob, not a directory name, so it has
# no prune-clause counterpart on the guard side either.
# shellcheck disable=SC2034 # read by every sourcing caller, not by this file
SEMGREP_PRUNE_DIRS=(vendor node_modules .build)
