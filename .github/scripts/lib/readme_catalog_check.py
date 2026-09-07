#!/usr/bin/env python3
# Replaces readme-catalog-check.sh's bash/regex mechanism (issue #101,
# issue #116) with a real tokenizer, the same shift find_workflow_call_targets.py
# already made on the YAML side (issue #118): the bash version accumulated
# several distinct failure modes - position-vs-content table-furniture
# confusion, a cell-count binding, exact-one-space rigidity, and (its most
# severe) a target filename interpolated into a live shell glob/regex
# pattern - all traceable to matching table structure and filenames with
# ad hoc string/pattern operations instead of a real per-row parse.
#
# The tokenizer itself went through two more designs after that (issue
# #116, rounds 20-23): first a line-oriented state machine that tried to
# hand-replicate GFM's block-precedence rules (an indented or fenced code
# block, an HTML comment) one construct at a time, then a lighter
# "ambiguity" check that only counted header-shaped lines. Every round
# found a new way to hide a decoy catalog - or, in the ambiguity design's
# case, a way to hide a decoy DATA ROW under a perfectly genuine, unique
# header - because a hand-rolled text-level check can only ever
# APPROXIMATE what actually renders as a live GFM table; GFM's own
# block-precedence rules (what an indented/fenced code block or an HTML
# comment absorbs, where a table's row-continuation stops) are exactly
# the part no line-level heuristic can get right in every case. This
# version stops approximating: it renders README.md through cmarkgfm
# (GitHub's own cmark-gfm C library, pinned via
# .github/requirements/cmarkgfm.in - the SAME renderer GitHub's servers
# use, not an independent reimplementation with its own edge cases to
# diverge on) and reads the catalog back out of the resulting HTML's real
# `<table>` elements. Content GitHub would never render as a table -
# indented/fenced code, the inside of an HTML comment (cmark-gfm's safe
# mode omits comment content from the output entirely, byte for byte
# verified 2026-09-07) - never becomes a `<table>` element in that HTML
# either, so it is structurally invisible to this check the same way it
# is to a human reading the rendered page, by construction rather than by
# enumeration.
#
# find_targets() is imported directly rather than invoked as a subprocess:
# the two-language split that used to exist here (this file now does BOTH
# halves in one process) needed a NUL-delimited temp-file handoff purely
# to survive an embedded raw newline in a filename crossing a process
# boundary - a hazard that does not exist when the producer and consumer
# are plain Python objects in the same interpreter.
import html.parser
import importlib.util
import os
import sys

import cmarkgfm

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


class _TableExtractor(html.parser.HTMLParser):
    """Extracts every rendered `<table>` from cmark-gfm's real GFM HTML
    output as `{"header": [cell, ...], "rows": [[cell, ...], ...]}`,
    using cmark-gfm's own `<thead>`/`<tbody>` distinction rather than
    guessing which row is the header from content or position - cmark-gfm
    already knows, since it parsed the real GFM table grammar (the
    alignment/separator row included) to produce this markup at all.

    Each cell is `(text, is_single_code_span)`. `is_single_code_span` is
    True only when the cell's ENTIRE content is one `` `code span` `` -
    no other text before, after, or beside it - mirroring this checker's
    own definition of a well-formed, single backtick-quoted name cell,
    now decided from cmark-gfm's real inline-parse result instead of a
    hand-rolled backtick-position check on raw cell text.
    """

    def __init__(self):
        super().__init__()
        self.tables = []
        self._table = None
        self._in_thead = False
        self._row = None
        self._in_cell = False
        self._code_depth = 0
        self._code_span_opens = 0
        self._plain_text = ""
        self._code_text = ""

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self._table = {"header": None, "rows": []}
        elif tag == "thead":
            self._in_thead = True
        elif tag == "tbody":
            self._in_thead = False
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._in_cell = True
            self._code_depth = 0
            self._code_span_opens = 0
            self._plain_text = ""
            self._code_text = ""
        elif tag == "code" and self._in_cell:
            if self._code_depth == 0:
                self._code_span_opens += 1
            self._code_depth += 1

    def handle_endtag(self, tag):
        if tag == "table" and self._table is not None:
            self.tables.append(self._table)
            self._table = None
        elif tag == "tr" and self._row is not None:
            # A <tr> only ever opens inside an open <table> (handle_starttag
            # only starts a row when self._table is not None), so this is
            # always true here - asserted rather than re-checked so a
            # future refactor that breaks the invariant fails loudly.
            assert self._table is not None
            if self._in_thead:
                self._table["header"] = self._row
            else:
                self._table["rows"].append(self._row)
            self._row = None
        elif tag in ("td", "th") and self._in_cell:
            # Symmetric invariant: a cell only ever opens inside an open
            # row (handle_starttag only sets self._in_cell when self._row
            # is not None).
            assert self._row is not None
            is_code = self._code_span_opens == 1 and not self._plain_text.strip()
            text = self._code_text if is_code else (self._plain_text + self._code_text).strip()
            self._row.append((text, is_code))
            self._in_cell = False
        elif tag == "code" and self._in_cell and self._code_depth > 0:
            self._code_depth -= 1

    def handle_data(self, data):
        if not self._in_cell:
            return
        if self._code_depth > 0:
            self._code_text += data
        else:
            self._plain_text += data


def _is_catalog_header(header):
    return (
        header is not None
        and len(header) == 3
        and header[0][0] == _HEADER_CELLS[0]
        and header[1][0] == _HEADER_CELLS[1]
        and header[2][0].startswith("Permissions")
    )


def parse_catalog_table(readme_path):
    """Yields `(kind, payload)` for the workflow catalog table actually
    rendered from README's content - `("header", None)` once, then
    `("row", name)` for each well-formed, backtick-quoted name cell, or
    `("malformed", None)` for a data row whose name cell is not a single
    `` `name` `` code span.

    The header is recognised by content (the exact literal cells
    "Workflow"/"Purpose" and a "Permissions"-prefixed third cell,
    tolerating real-world trailing text like this repo's own
    "...Permissions the caller must grant") among cmark-gfm's OWN
    `<thead>` rows in the rendered document - never by guessing which
    line is the header from raw text, since a real GFM table's header is
    unambiguous once actually parsed. Raises `ValueError` if more than
    one rendered table matches: two genuinely-rendered, human-visible
    catalog tables in one README is a real ambiguity a human has to
    resolve, not something this function can guess past (issue #116).
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
        text = handle.read()

    extractor = _TableExtractor()
    extractor.feed(cmarkgfm.github_flavored_markdown_to_html(text))

    catalog_tables = [table for table in extractor.tables if _is_catalog_header(table["header"])]
    if len(catalog_tables) > 1:
        raise ValueError(
            f"README.md renders {len(catalog_tables)} tables that look like the workflow "
            "catalog - remove the extra one(s) so the real catalog is unambiguous "
            "(see issue #116)."
        )
    if not catalog_tables:
        return

    yield ("header", None)
    for row in catalog_tables[0]["rows"]:
        name_text, name_is_code = row[0] if row else ("", False)
        if name_is_code and name_text:
            yield ("row", name_text)
        else:
            yield ("malformed", None)


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
        # Ambiguous catalog-table count - see parse_catalog_table()'s own
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
        # row_names never contains an empty string: parse_catalog_table()
        # only yields ("row", name) when the cell rendered as a single,
        # non-empty code span - an empty backtick pair (`` `` ``) renders
        # as literal text, not an empty <code> element (verified live,
        # 2026-09-07), so it already falls into the "malformed" path
        # above instead of reaching here.
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
