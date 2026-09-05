#!/usr/bin/env python3
# Sourced (via `python3 <this file> <workflows_dir>`) by
# readme-catalog-check.sh's find_workflow_call_targets() to detect a
# workflow_call trigger via a real YAML parse instead of pattern-matching
# the raw text - issue #118. The old sed/grep heuristic accepted two known,
# documented gaps at the time of this replacement: the scalar/flow-sequence
# trigger shorthand (`on: workflow_call` / `on: [push, workflow_call]`) and
# a byte-inexact `on:` line (a quoted `'on':` key). A real parser closes
# both by construction - it evaluates the trigger's actual YAML shape and
# value, not the literal bytes of the line that introduces it. (A THIRD
# gap, a job literally named `workflow_call` being misread as the trigger,
# was already closed earlier in this same effort - issue #101's
# range-scoping fix, not this replacement - by scoping the old heuristic's
# search to the `on:` block rather than the whole file; re-derive:
# `git log --format='%h %ad %s' --date=iso -- .github/scripts/lib/readme-catalog-check.sh`.)
#
# Prints one NUL-terminated, unsanitised basename per matching file to
# stdout - NUL rather than newline, because a git-tracked filename may
# itself contain an embedded raw newline (see annotation-sanitize.sh's own
# header for why that must survive intact into sanitize_for_annotation()
# rather than being consumed by a newline-based split first). Sanitising
# the printed name for CI-annotation forgery is the CALLER's job
# (readme-catalog-check.sh already has sanitize_for_annotation() for this,
# and every other annotation producer in this repo routes through that
# same function rather than a second, independently-drifting copy -
# re-derive: `git grep -n sanitize_for_annotation -- .github`).
#
# Known limitation: a file with TWO top-level `on:` keys resolves via
# YAML's own last-key-wins rule, so a workflow_call trigger under the FIRST
# `on:` block is silently discarded if a second `on:` block follows. Not
# fixed here because it is already independently gated: this repo's
# yamllint job (yamllint.yml) never overrides key-duplicates, so that rule
# stays at yamllint's default `error` level and rejects a duplicate
# top-level key. Re-derive by extracting the job's OWN current `-d`
# argument live, rather than a hand-copied string this comment already
# drifted from once (a prior version claimed "runs every rule at its
# default", which was already false at the time) - a copy cannot detect
# the next divergence either, this can:
#   printf 'on:\n    workflow_call:\non:\n    push:\n' | yamllint -d "$(
#       grep -oP '(?<=-d ")[^"]+' .github/workflows/yamllint.yml
#   )" -
# (using the version pinned in .github/requirements/yamllint.in) reports
# `key-duplicates` and exits 1.
import glob
import os
import re
import sys

import yaml

# Mirrors annotation-sanitize.sh's sanitize_for_annotation() jq filter
# (its readonly ANNOTATION_SANITIZE_JQ_FILTER constant - re-derive: `grep -n
# 'readonly ANNOTATION_SANITIZE_JQ_FILTER=' .github/scripts/lib/annotation-sanitize.sh`;
# test-sanitize-stderr-parity.sh is the drift guard that actually enforces
# this, not this comment) exactly, in Python: this
# script's own stderr diagnostic below is a SECOND CI-annotation producer
# in this repo that has nothing to route through the bash function, since
# it runs in a separate process the bash caller only pipes stdout from
# (readme-catalog-check.sh's `python3 ... > "${tmp_file}"` never touches
# stderr, which flows straight into the Actions job log unfiltered) - a
# real, git-trackable filename or PyYAML exception message containing a
# raw newline would otherwise forge a second, attacker-authored `::error::`
# line the same way annotation-sanitize.sh's own header documents. Order
# matters: percent-escape first, or a literal `%0D`/`%0A` in the source
# text would be indistinguishable from an already-escaped sequence once
# the runner decodes it back. `[:cntrl:]` in jq is Unicode-aware (C0
# controls, DEL, and C1 controls such as U+0085 NEL) - re.sub() operates on
# Python's own Unicode codepoints already, so no decode step is needed
# here the way jq's own UTF-8 requirement forces on the bash side.
_CNTRL_PATTERN = re.compile("[\x00-\x1f\x7f\u0080-\u009f]")


def _sanitize_for_stderr(text):
    return _CNTRL_PATTERN.sub(" ", text.replace("%", "%25"))


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

    if isinstance(trigger, (dict, list)):
        return "workflow_call" in trigger
    if isinstance(trigger, str):
        return trigger == "workflow_call"
    return False


def find_targets(workflows_dir):
    # Two separately-sorted globs, concatenated - preserving the sed/grep-era
    # `*.yml` results, then `*.yaml` results order. No current bash-side
    # assertion depends on this cross-extension ordering (every one either
    # matches order-independently or, where the raw output is compared,
    # only ever has one matching file at that point in its fixture), but
    # test_returns_yml_then_yaml_sorted_within_each_group in
    # test_find_workflow_call_targets.py does pin it directly - preserving
    # it costs nothing and avoids a gratuitous behavior change.
    paths = sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))) + sorted(
        glob.glob(os.path.join(workflows_dir, "*.yaml"))
    )

    for path in paths:
        if os.path.islink(path):
            # A git-tracked symlink (mode 120000) can point anywhere on the
            # runner filesystem, and glob()/open() do not distinguish it
            # from a real file. Skipped before ever opening it: yaml.safe_load()
            # is called on an open FILE HANDLE below, not a string, and
            # PyYAML's Mark.get_snippet() returns None whenever its buffer
            # is None - which it always is for a stream/file-object source,
            # not for a string. Re-derive (the string case prints the
            # offending source line with a caret, the io.StringIO/stream
            # case prints only path/line/column):
            #   python3 -c "
            #   import yaml, io
            #   for src in ('a: {b', io.StringIO('a: {b')):
            #       try:
            #           yaml.safe_load(src)
            #       except Exception as e:
            #           print(str(e))
            #   "
            # so a parse failure on the symlink's TARGET cannot leak its
            # content via the exception message this loop's own
            # except-branch below prints. What a symlink WOULD still let a
            # fork PR do without this guard: get a successfully-parsed
            # target's basename echoed on stdout as a "workflow_call
            # target" whenever the file IT points at happens to structurally
            # declare one - a narrow, low-value existence/shape oracle about
            # an arbitrary file on the runner, not a content leak.
            print(
                "find_workflow_call_targets.py: "
                f"{_sanitize_for_stderr(os.path.basename(path))} is a symlink, skipping "
                "(a workflow file has no reason to be one)",
                file=sys.stderr,
            )
            continue

        try:
            with open(path, "r", encoding="utf-8") as handle:
                doc = yaml.safe_load(handle)
        except Exception as exc:
            # Deliberately broad, not narrowed to yaml.YAMLError:
            # `open()`/`yaml.safe_load()` on one bad file can also raise
            # UnicodeDecodeError (non-UTF-8 bytes), OSError (permission
            # denied), or RecursionError (a pathologically deep flow
            # sequence) - none a yaml.YAMLError subclass. Without this,
            # a single non-UTF-8 byte in one file, with a genuine
            # workflow_call trigger in a sibling that sorts after it,
            # otherwise propagates out of this loop uncaught - the whole
            # process exits nonzero having yielded nothing on stdout. Before
            # readme-catalog-check.sh's own fix for this, that made the
            # caller's completeness check silently report SUCCESS with no
            # ::error:: at all, rather than flagging the real target as
            # undocumented - see that file's own comment on
            # assert_readme_catalog_complete() for the exact mechanism. A
            # malformed workflow file is caught separately by this repo's
            # own yamllint job, so this script's only job here is reporting
            # which files declare workflow_call - a stderr line naming the
            # skipped file is the proportionate response to any single
            # file's processing failure, not a hard failure of the whole
            # scan. Both interpolated values are routed through
            # _sanitize_for_stderr() - a git-tracked filename can carry an
            # embedded raw newline (the exact forgery channel this file's
            # own header already accounts for on the stdout side), and
            # PyYAML's own exception message re-embeds the full raw path
            # in its "in '<path>', line N, column M" context, so `exc`
            # needs the same treatment as the bare filename, not just
            # os.path.basename(path) alone.
            print(
                "find_workflow_call_targets.py: "
                f"{_sanitize_for_stderr(os.path.basename(path))} could not be processed, skipping: "
                f"{_sanitize_for_stderr(str(exc))}",
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
