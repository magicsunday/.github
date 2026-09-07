#!/usr/bin/env python3
# Replaces readme-catalog-check.sh's bash/regex mechanism (issue #101,
# issue #116) with a real tokenizer, the same shift find_workflow_call_targets.py
# already made on the YAML side (issue #118): every bug the bash version
# accumulated across 17 review rounds (round 9's position-vs-content
# furniture confusion, round 13's cell-count binding, round 15's exact-
# one-space rigidity, rounds 16-17's regex-metacharacter escaping) traces
# back to the same root cause - interpolating one piece of caller-
# controlled text (a filename) into a live shell glob/regex pattern built
# from another. A real per-row split removes the pattern-construction step
# entirely: a table cell is compared to a filename with plain string
# equality, which has no metacharacter-interpretation hazard by
# construction, the same way `case`'s own quoting protected the ORIGINAL
# bash mechanism until an intermediate rewrite dropped it (git blame this
# repo's history for the exact sequence).
#
# find_workflow_call_targets() is imported directly rather than invoked as
# a subprocess: the two-language split that used to exist here (this file
# now does BOTH halves in one process) needed a NUL-delimited temp-file
# handoff purely to survive an embedded raw newline in a filename crossing
# a process boundary - a hazard that does not exist when the producer and
# consumer are plain Python objects in the same interpreter.
import importlib.util
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "find_workflow_call_targets", os.path.join(_LIB_DIR, "find_workflow_call_targets.py")
)
# spec_from_file_location() is typed as returning Optional[ModuleSpec] for a
# path it cannot resolve at all - not a real possibility here, since
# _LIB_DIR is this file's own known-good directory (mirrors
# test_find_workflow_call_targets.py's identical assertion for the same
# reason).
assert _spec is not None and _spec.loader is not None
find_workflow_call_targets = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(find_workflow_call_targets)

_HEADER_CELLS = ("Workflow", "Purpose")
_SEPARATOR_CELL = re.compile(r"^:?-+:?$")


def _sanitize(text):
    # Mirrors annotation-sanitize.sh's sanitize_for_annotation() jq filter
    # (re-derive: `grep -n 'readonly ANNOTATION_SANITIZE_JQ_FILTER=' \
    # .github/scripts/lib/annotation-sanitize.sh`) via
    # find_workflow_call_targets._sanitize_for_stderr(), which already
    # implements the identical fold in Python for that module's own stderr
    # diagnostics. Reusing it here - rather than a second, independently
    # drifting copy - is only possible because this file imports that
    # module directly into the same process instead of shelling out to it;
    # test-sanitize-stderr-parity.sh is the drift guard that keeps this
    # (and the bash/jq original) in lockstep, not a comment repeating what
    # the filter does.
    return find_workflow_call_targets._sanitize_for_stderr(text)


def split_table_row(line):
    """Splits one GFM table row into its pipe-delimited, stripped cells.

    Returns None for a line that is not table-row-shaped at all (does not
    start with `|`). Every `|` is a column boundary, full stop - no
    backslash-escaping is recognised. GFM itself lets a cell escape a
    literal pipe with `\\|`, but adding that here would solve a problem
    this repository does not have: a real GitHub Actions workflow filename
    cannot contain `|` (Known limitation, issue #116, unchanged from the
    bash predecessor's own accepted residual) - a name that did would
    still fail closed via the malformed-row branch below, just with a
    generic diagnosis rather than a specific one, exactly as before.
    Recognising an escape sequence that never fires in practice only adds
    a second, untested code path with its own edge cases (an escaped
    escape character, a trailing backslash at end of cell) for no real
    gain - the KISS/YAGNI call this rewrite exists to make, not avoid.
    """
    stripped = line.strip()
    if not stripped.startswith("|"):
        return None

    body = stripped[1:]
    if body.endswith("|"):
        body = body[:-1]

    return [cell.strip() for cell in body.split("|")]


def _is_header(cells):
    return (
        cells is not None
        and len(cells) == 3
        and cells[0] == _HEADER_CELLS[0]
        and cells[1] == _HEADER_CELLS[1]
        and cells[2].startswith("Permissions")
    )


def _is_separator(cells):
    return cells is not None and len(cells) == 3 and all(_SEPARATOR_CELL.match(cell) for cell in cells)


def parse_catalog_table(readme_path):
    """Yields `(kind, payload)` for each line of README's workflow catalog
    table - `("header", None)`, `("separator", None)`, `("row", name)` for
    a well-formed `` | `name` | ... | `` data row, or `("malformed", line)`
    for anything else inside the table's span.

    The table's span is the first header line (recognised by content: the
    exact literal cells "Workflow"/"Purpose" and a "Permissions"-prefixed
    third cell, tolerating real-world trailing text like this repo's own
    "...Permissions the caller must grant" - never by position) through
    the next blank line - and STOPS there for good. Earlier bash rounds
    fought a class of bug where a later, real occurrence of the header
    text (e.g. two catalog-shaped tables in one README) restarted a
    sed range a second time, concatenating an embedded blank line into the
    middle of the extracted text; a single linear pass that returns
    unconditionally at the first blank line makes that restart structurally
    impossible rather than merely guarded against - there is exactly one
    catalog table this function will ever look at, by construction.

    The separator (a GFM alignment row) is recognised only on the line
    immediately after a just-recognised header - not by table-wide
    position, not by shape alone at any position - closing both classes
    of silent pass earlier bash rounds found the hard way: a missing
    separator no longer shifts a real row into a skipped slot (nothing is
    ever skipped by position), and a separator-shaped line elsewhere in
    the table (a blanked-out row, a duplicated separator) is never
    mistaken for furniture just because of its shape.
    """
    with open(readme_path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    started = False
    after_header = False
    for line in lines:
        cells = split_table_row(line)
        is_header = _is_header(cells)

        if not started:
            if is_header:
                started = True
                after_header = True
                yield ("header", None)
            continue

        if line.strip() == "":
            return

        if is_header:
            after_header = True
            yield ("header", None)
            continue

        if after_header:
            after_header = False
            if _is_separator(cells):
                yield ("separator", None)
                continue

        if cells is None or len(cells) != 3:
            yield ("malformed", line)
            continue

        name_cell = cells[0]
        if len(name_cell) >= 2 and name_cell[0] == "`" and name_cell[-1] == "`" and name_cell.count("`") == 2:
            yield ("row", name_cell[1:-1])
        else:
            yield ("malformed", line)


def check(workflows_dir, readme_path):
    """Returns a list of `::error::`-ready messages (empty if the catalog
    is complete and accurate): fails closed in both directions - every
    workflow_call target from find_workflow_call_targets() must have its
    own catalog row (issue #101), and every catalog row must still name
    one of those targets (issue #116, the reverse direction this file's
    predecessor was originally created to add).
    """
    errors = []

    targets = list(find_workflow_call_targets.find_targets(workflows_dir))
    row_names = []

    for kind, payload in parse_catalog_table(readme_path):
        if kind == "row":
            row_names.append(payload)
        elif kind == "malformed":
            errors.append(
                "a catalog row's name cell in README.md is not a single backtick-quoted "
                "name immediately followed by the column separator - fix the row (see issue #116)."
            )

    for target in targets:
        if target not in row_names:
            errors.append(
                f"{_sanitize(target)} declares workflow_call: but is not listed in "
                "README.md's workflow catalog - add it (see issue #101)."
            )

    for name in row_names:
        if not name:
            errors.append(
                "an empty backtick cell in README.md's workflow catalog names no workflow "
                "- remove the row (see issue #116)."
            )
            continue
        if name in targets:
            continue
        if os.path.isfile(os.path.join(workflows_dir, name)):
            message = (
                "the file exists and declares no workflow_call: trigger the parser could "
                "read - remove the row or restore the trigger"
            )
        else:
            message = f"the file is missing under {workflows_dir} - remove the row or restore the file"
        errors.append(f"{_sanitize(name)} is listed in README.md's workflow catalog, but {message} (see issue #116).")

    return errors


def main(argv):
    if len(argv) != 3:
        print("usage: readme_catalog_check.py <workflows_dir> <readme_file>", file=sys.stderr)
        return 2

    errors = check(argv[1], argv[2])
    for message in errors:
        print(f"::error::{message}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
