#!/usr/bin/env python3
# Sourced (via `python3 <this file> <workflows_dir>`) by
# readme-catalog-check.sh's find_workflow_call_targets() to detect a
# workflow_call trigger via a real YAML parse instead of pattern-matching
# the raw text - issue #118. The old sed/grep heuristic accepted two known,
# documented gaps: the scalar/flow-sequence trigger shorthand (`on:
# workflow_call` / `on: [push, workflow_call]`) and a byte-inexact `on:`
# line (a quoted `'on':` key). A real parser closes all three by
# construction - it evaluates the trigger's actual YAML shape and value,
# not the literal bytes of the line that introduces it.
#
# Prints one NUL-terminated, unsanitised basename per matching file to
# stdout - NUL rather than newline, because a git-tracked filename may
# itself contain an embedded raw newline (see annotation-sanitize.sh's own
# header for why that must survive intact into sanitize_for_annotation()
# rather than being consumed by a newline-based split first). Sanitising
# the printed name for CI-annotation forgery is the CALLER's job
# (readme-catalog-check.sh already has sanitize_for_annotation() for this
# and every other producer in this repo routes through the same one
# function, rather than a second, independently-drifting copy here).
import glob
import os
import sys

import yaml


def _has_workflow_call_trigger(doc):
    if not isinstance(doc, dict):
        return False

    # PyYAML's SafeLoader resolves an unquoted `on:` mapping key to the
    # boolean True under YAML 1.1's implicit-typing rules (the "Norway
    # problem" - verified live: `yaml.safe_load("on:\n    workflow_call:\n")`
    # yields `{True: {"workflow_call": None}}`, not a string key). GitHub
    # Actions' own convention is exactly this bare, unquoted form, so the
    # real trigger mapping normally lives under the key True, not the
    # string "on". Checking both here also closes the old sed/grep
    # detector's own documented gap for the rarer, quoted `'on':` form,
    # which parses as the string key instead - a fix this script gets for
    # free from using a real parser, not a separately-tracked feature.
    trigger = doc.get(True, doc.get("on"))

    if isinstance(trigger, dict):
        return "workflow_call" in trigger
    if isinstance(trigger, list):
        return "workflow_call" in trigger
    if isinstance(trigger, str):
        return trigger == "workflow_call"
    return False


def find_targets(workflows_dir):
    # Two separately-sorted globs, concatenated - matching the iteration
    # order the bash caller's own tests were written against
    # (`*.yml` results, then `*.yaml` results), so swapping the underlying
    # implementation does not reorder any existing assertion's expected
    # output.
    paths = sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))) + sorted(
        glob.glob(os.path.join(workflows_dir, "*.yaml"))
    )

    for path in paths:
        try:
            with open(path, "r", encoding="utf-8") as handle:
                doc = yaml.safe_load(handle)
        except yaml.YAMLError as exc:
            # Not fatal: the old sed/grep detector also produced no match
            # on unparsable text, just silently. A malformed workflow file
            # is caught separately by this repo's own yamllint job - this
            # script's job is only to report which files declare
            # workflow_call, so a stderr line (visible in the CI log, unlike
            # the old detector's total silence) is the proportionate
            # response here, not a hard failure of this unrelated check.
            print(
                f"find_workflow_call_targets.py: {os.path.basename(path)} is not valid YAML, skipping: {exc}",
                file=sys.stderr,
            )
            continue

        if _has_workflow_call_trigger(doc):
            yield os.path.basename(path)


def main(argv):
    if len(argv) != 2:
        print("usage: find_workflow_call_targets.py <workflows_dir>", file=sys.stderr)
        return 2

    out = sys.stdout.buffer
    for name in find_targets(argv[1]):
        # fsencode, not a plain UTF-8 .encode(): a filename is an arbitrary
        # byte sequence on a POSIX filesystem, and glob() already decoded it
        # with surrogateescape - fsencode reverses that losslessly, while a
        # plain .encode() would raise on a name that round-trips through
        # surrogateescape.
        out.write(os.fsencode(name))
        out.write(b"\0")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
