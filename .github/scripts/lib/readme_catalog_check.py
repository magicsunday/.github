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
_FENCE_LINE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


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


def _leading_indent_columns(line):
    """Returns `line`'s leading indentation in CommonMark/GFM columns: a
    space advances one column, a tab advances to the next multiple of 4 -
    matching GFM's own tab-stop expansion, so this agrees with what GitHub
    actually renders. A raw whitespace-CHARACTER count does not: `" \\t"`,
    `"  \\t"` and `"   \\t"` are all 4 effective columns (the same
    code-block threshold as 4 literal spaces or a leading tab) despite
    being 2, 3 and 4 raw characters respectively - a fixed-width character
    slice missed exactly that range (issue #116, round 20).
    """
    column = 0
    for char in line:
        if char == " ":
            column += 1
        elif char == "\t":
            column += 4 - (column % 4)
        else:
            break
    return column


def split_table_row(line):
    """Splits one GFM table row into its pipe-delimited, stripped cells.

    Returns None for a line that is not table-row-shaped at all: does not
    start with `|`, or has 4+ columns of leading indentation (see
    `_leading_indent_columns()`) - GFM gives an indented code block
    precedence over table recognition, so a README example wrapped in one
    must never be mistaken for the real catalog (issue #116; a decoy
    header/separator/row block indented this way would otherwise open the
    table early and make the real one unreachable, since the table span
    ends for good at the first blank line). A FENCED code block (`` ``` ``
    or `~~~`) is excluded the same way, but at the `parse_catalog_table()`
    level instead, since recognising a fence means tracking state across
    lines rather than judging one line in isolation. Every `|` is a column
    boundary, full stop - no backslash-escaping is recognised. GFM itself
    lets a cell escape a literal pipe with `\\|`, but adding that here
    would solve a problem this repository does not have: no workflow file
    under `.github/workflows/` currently uses `|` in its name (Known
    limitation, issue #116; re-derive: `ls .github/workflows | grep -c '|'`
    should print 0) - a name that did would still fail closed via the
    malformed-row branch below, just with a generic diagnosis rather than
    a specific one. Recognising an escape sequence that never fires in
    practice only adds a second, untested code path with its own edge
    cases (an escaped escape character, a trailing backslash at end of
    cell) for no real gain - the KISS/YAGNI call this rewrite exists to
    make, not avoid.
    """
    if _leading_indent_columns(line) >= 4:
        return None

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
    the next blank line, and stops there for good: a single linear pass
    that returns unconditionally at the first blank line makes restarting
    on a later, unrelated header-shaped line (e.g. two catalog-shaped
    tables in one README) structurally impossible rather than merely
    guarded against - there is exactly one catalog table this function
    will ever look at, by construction.

    The separator (a GFM alignment row) is recognised only on the line
    immediately after a just-recognised header - never by table-wide
    position, never by shape alone at any position - so a missing
    separator never shifts a real row into a skipped slot, and a
    separator-shaped line elsewhere in the table is never mistaken for
    furniture just because of its shape.

    A fenced code block (a line starting with 0-3 spaces then `` ``` `` or
    `~~~`, closed by a later line of the same kind) is skipped in its
    entirety, fence delimiters included: GFM gives it precedence over
    every other block type the same way it does an indented code block,
    so a decoy catalog wrapped in a bare, UNindented fence (` ``` `, no
    leading whitespace at all) is just as invisible on the rendered page
    as an indented one, and must be exactly as invisible to this parser -
    a decoy inside a fence needs no indentation trick at all to open the
    table early and hide the real one, unlike the indentation guard
    `split_table_row()` applies line-by-line (issue #116, round 20).

    An HTML comment (`<!--` through `-->`, on one line or spanning
    several) is skipped the same way, for the same reason: GFM renders it
    as nothing at all, so a decoy catalog hidden inside one is invisible
    to a human reviewer but would otherwise be plain text to this
    line-oriented parser (issue #116, round 20). A line that opens a
    comment without also closing it on the same line is treated as
    commented through to the line that closes it, inclusive - the
    conservative direction for a security gate whenever a same-line
    close/reopen would otherwise need to be judged exactly.
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

    started = False
    after_header = False
    in_fence = False
    in_comment = False
    for line in lines:
        # Fence state takes absolute priority over comment detection: GFM
        # treats a fenced block's content as opaque plain text, so a
        # fence line containing an unclosed `<!--` (e.g. fence content
        # that just happens to include that byte sequence) must never be
        # allowed to set in_comment - doing so let the fence's own closing
        # delimiter be swallowed by the in_comment branch below instead of
        # ever being seen, leaving BOTH flags stuck for the rest of the
        # file (round 20, live-demonstrated: the parser silently yielded
        # nothing at all past such a line, hiding the real catalog).
        if _FENCE_LINE.match(line):
            in_fence = not in_fence
            continue

        if in_fence:
            continue

        if in_comment:
            if "-->" in line:
                in_comment = False
            continue

        if "<!--" in line:
            in_comment = "-->" not in line[line.index("<!--") :]
            continue

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
