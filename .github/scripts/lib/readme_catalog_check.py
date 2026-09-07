#!/usr/bin/env python3
# Replaces readme-catalog-check.sh's bash/regex mechanism (issue #101,
# issue #116) with a real tokenizer, the same shift find_workflow_call_targets.py
# already made on the YAML side (issue #118): the bash version accumulated
# several distinct failure modes - position-vs-content table-furniture
# confusion, a cell-count binding, exact-one-space rigidity, and (its most
# severe) a target filename interpolated into a live shell glob/regex
# pattern - all traceable to matching table structure and filenames with
# ad hoc string/pattern operations instead of a real per-row parse. A real
# per-row split removes every one of these at once: cells are classified
# by content and position in the token stream rather than by text search,
# and a table cell is compared to a filename with plain string equality,
# which has no metacharacter-interpretation hazard by construction.
#
# find_targets() is imported directly rather than invoked as a subprocess:
# the two-language split that used to exist here (this file now does BOTH
# halves in one process) needed a NUL-delimited temp-file handoff purely
# to survive an embedded raw newline in a filename crossing a process
# boundary - a hazard that does not exist when the producer and consumer
# are plain Python objects in the same interpreter.
#
# parse_catalog_table() does not try to tell a real catalog header apart
# from a decoy one hidden inside some GFM construct that renders as
# opaque/invisible on GitHub (an indented or fenced code block, an HTML
# comment, a raw HTML block, YAML front matter, ...). An earlier design
# tried exactly that, enumerating one such construct at a time as each
# was found to hide a decoy well enough to defeat this check while
# staying invisible to a human reviewer - and every round of review
# found another way to hide one, because GFM has many block types with
# precedence over table parsing and hand-replicating all of them (plus
# every one of their own closing-delimiter edge cases: matching
# character, matching-or-greater run length, no trailing content after
# the run, ...) is an open-ended chase, not a fixable bug. Instead: scan
# the WHOLE file for every line that looks like the catalog header (by
# content, the same way it always has), and treat finding MORE THAN ONE
# such line anywhere in the file as itself a hard, fail-closed error -
# regardless of what construct a second one might be hiding inside. A
# decoy header hidden in a fence/comment/wherever is exactly as visible
# to this content-based scan as the real one, so it can no longer be
# silently trusted OR silently ignored; the file is simply ambiguous and
# a human has to remove the extra occurrence. This closes the entire bug
# class in one property instead of one construct at a time (issue #116).
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
    this repository does not have: no workflow file under
    `.github/workflows/` currently uses `|` in its name (Known
    limitation, issue #116; re-derive: `ls .github/workflows | grep -c '|'`
    should print 0) - a name that did would still fail closed via the
    malformed-row branch below, just with a generic diagnosis rather than
    a specific one. Recognising an escape sequence that never fires in
    practice only adds a second, untested code path with its own edge
    cases (an escaped escape character, a trailing backslash at end of
    cell) for no real gain - the KISS/YAGNI call this rewrite exists to
    make, not avoid.
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

    The header is recognised by content (the exact literal cells
    "Workflow"/"Purpose" and a "Permissions"-prefixed third cell,
    tolerating real-world trailing text like this repo's own
    "...Permissions the caller must grant") wherever it occurs in the
    file - including inside a fenced/indented code block, an HTML
    comment, or any other GFM construct that would render it as
    invisible/opaque on GitHub. This function does not try to tell such a
    decoy apart from the real header (see this module's header comment
    for why that chase doesn't end): it raises ValueError instead if MORE
    THAN ONE header-shaped line exists anywhere in the file, refusing to
    guess which one is real. With exactly one, the table's span runs from
    there through the next blank line.

    The separator (a GFM alignment row) is recognised only on the line
    immediately after the header - never by table-wide position, never
    by shape alone at any position - so a missing separator never shifts
    a real row into a skipped slot, and a separator-shaped line elsewhere
    in the table is never mistaken for furniture just because of its
    shape.
    """
    if os.path.islink(readme_path):
        # Mirrors find_targets()'s own symlink guard on workflow files, for
        # the identical reason: README.md's content (including its git
        # blob mode) is fully attacker-controlled via a PR, so a symlink
        # committed in its place would otherwise be followed transparently
        # into whatever it points at on the runner - an existence/shape
        # oracle about an arbitrary path, the same narrow hazard
        # find_targets()'s comment already documents for workflow files.
        raise OSError(f"{readme_path} is a symlink, refusing to follow it")

    with open(readme_path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    header_indexes = [i for i, line in enumerate(lines) if _is_header(split_table_row(line))]
    if len(header_indexes) > 1:
        raise ValueError(
            f"README.md contains {len(header_indexes)} lines that look like the workflow "
            "catalog header - remove the extra one(s) so the real catalog is unambiguous "
            "(see issue #116)."
        )
    if not header_indexes:
        return

    yield ("header", None)
    after_header = True
    for line in lines[header_indexes[0] + 1 :]:
        if line.strip() == "":
            return

        cells = split_table_row(line)

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
    workflow_call target from find_targets() must have its own catalog row
    (issue #101), and every catalog row must still name one of those
    targets (issue #116, the reverse direction this file's predecessor was
    originally created to add).
    """
    try:
        rows = list(parse_catalog_table(readme_path))
    except (OSError, UnicodeDecodeError) as exc:
        # README.md is a single, always-required input, unlike the
        # per-file open()/yaml.safe_load() find_targets() above wraps the
        # same way: there is no sibling file to fall back to, so a decode
        # or read failure here becomes one clear ::error:: instead of
        # propagating as an uncaught traceback (which would still fail
        # the CI job, just with no actionable diagnosis). Returns
        # immediately rather than falling through to the target/row-name
        # comparisons below: with no real row_names extracted, every
        # single target would otherwise ALSO be reported as undocumented,
        # burying the one actionable message (the unreadable file) in a
        # misleading cascade of unrelated-looking errors.
        return [f"README.md could not be read: {_sanitize(str(exc))} - fix the file (see issue #116)."]
    except ValueError as exc:
        # Ambiguous header count - see parse_catalog_table()'s own
        # docstring and this module's header comment for why this is a
        # hard error rather than a best-effort guess. Same early-return
        # rationale as the read-failure branch above: no row_names exist
        # to compare against either.
        return [str(exc)]

    errors = []
    targets = list(find_workflow_call_targets.find_targets(workflows_dir))
    row_names = []

    for kind, payload in rows:
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
        annotation = f"::error::{message}"
        # A workflow filename is decoded from raw POSIX bytes via glob()'s
        # surrogateescape (see find_workflow_call_targets.py's own comment
        # on this), so a non-UTF-8 byte in one survives as a lone
        # surrogate codepoint all the way into `message` - _sanitize()
        # folds control characters and escapes `%`, but does not touch
        # surrogates, and printing one to a real UTF-8 stdout raises
        # UnicodeEncodeError uncaught (verified live) instead of the
        # intended ::error:: exiting cleanly. Round-tripping through
        # encode/decode with backslashreplace turns it into readable
        # escaped text instead of crashing, without depending on the
        # concrete stdout object supporting reconfigure() (a test's
        # io.StringIO redirect does not) - this is a diagnostic message,
        # not a byte-exact data channel, so losing round-trip fidelity
        # here costs nothing.
        print(annotation.encode("utf-8", "backslashreplace").decode("utf-8"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
