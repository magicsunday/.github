#!/usr/bin/env python3
# Replaces readme_catalog_check.py's rendered-HTML table extraction (issue
# #101, issue #116) with a generated-artefact model: .github/workflow-catalog.json
# is the source of truth a PR author edits, README.md's catalog table is
# GENERATED from it, and a freshness check (render_table() vs. what is
# actually committed between the markers) is the only thing that ever looks
# at README.md's content. That freshness check is a byte-for-byte string
# comparison, never a markdown/HTML parse.
#
# This retires a long run of hand-rolled extractor hardening against
# every way GitHub-flavoured Markdown/HTML can be nested, unbalanced or
# spoofed (see readme_catalog_check.py's own git history for the sequence
# of fixes: `git log -- .github/scripts/lib/readme_catalog_check.py`) -
# each fix closed one construct and left the next one for the following
# round, because the fundamental problem was re-deriving a live rendering
# engine's structure from PR-controlled markdown by hand. Moving the
# source of truth to JSON and the README to a generated artefact removes
# that problem for README.md's own committed bytes: a decoy row can no
# longer "look real to a human but not match the checker" there, because
# the checker never interprets README.md's markdown - only compares it
# byte-for-byte to render_table()'s output. It does NOT make catalog
# VALUES trustworthy content, though - .github/workflow-catalog.json is
# exactly as PR-controlled as README.md ever was, and render_table()
# splices its strings into the generated markdown - see
# _reject_unsafe_cell_text()'s own comment for the concrete constructs
# (table-splicing punctuation, raw HTML tags, backtick break-out, control
# and separator characters) that a name/purpose/permission string is
# rejected for rather than passed through unescaped.
#
# find_targets() is imported directly, not invoked as a subprocess - same
# rationale as the file this replaces: producer and consumer are plain
# Python objects in one process, so no NUL-delimited handoff is needed.
import importlib.util
import json
import os
import sys
import unicodedata

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "find_workflow_call_targets", os.path.join(_LIB_DIR, "find_workflow_call_targets.py")
)
# spec_from_file_location() is typed as returning Optional[ModuleSpec] for a
# path it cannot resolve at all - not a real possibility here, since
# _LIB_DIR is this file's own known-good directory.
assert _spec is not None and _spec.loader is not None
find_workflow_call_targets = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(find_workflow_call_targets)

_BEGIN_MARKER = "<!-- workflow-catalog:start -->"
_END_MARKER = "<!-- workflow-catalog:end -->"

_TABLE_HEADER = "| Workflow | Purpose | Permissions the caller must grant |\n| --- | --- | --- |\n"


def _sanitize(text):
    # See readme_catalog_check.py's own _sanitize() history (git log) for
    # why this reuses find_workflow_call_targets._sanitize_for_stderr()
    # rather than a second copy.
    return find_workflow_call_targets._sanitize_for_stderr(text)


def _reject_unsafe_cell_text(catalog_path, name, field, value, *, allow_backtick):
    # `|` would splice an extra column into render_table()'s markdown row
    # (GFM's table-cell grammar splits on every unescaped `|` regardless of
    # code-span/backtick state - checked against cmark-gfm's own
    # table_cell rule, 2026-09-07); `<`/`>` let a value construct raw HTML tags
    # (`</td><td>...`) that a spec-compliant renderer implicitly closes
    # the current cell/row for, forging a sibling table row or column with
    # no `|` needed at all - live-demonstrated end to end through a real
    # renderer, round 29 (round 28's fix covered only the `|`/newline
    # mechanism, not this class). Embedding either marker string would let
    # a later --write lock onto the wrong occurrence instead of the real
    # one. A Unicode category-C character (Cc/Cf/Cs/Co/Cn - control,
    # format incl. bidi overrides, surrogate, private-use, unassigned) or
    # a Zl/Zp separator covers a literal newline or line/paragraph
    # separator (ends the table early, pushing the real remaining cells
    # into unrelated rendered prose) and a Trojan-Source-style bidi
    # override with no hand-picked list of individual characters.
    if (
        "|" in value
        or "<" in value
        or ">" in value
        or _BEGIN_MARKER in value
        or _END_MARKER in value
        or any(unicodedata.category(ch) in ("Zl", "Zp") or unicodedata.category(ch)[0] == "C" for ch in value)
    ):
        raise ValueError(
            f"{catalog_path}: the entry for {_sanitize(name)}'s {field!r} must not contain a `|`, "
            "a `<`/`>`, a generated-block marker, or a Unicode control/format/separator character "
            "- any of those would corrupt or misrepresent the generated table (see issue #116)."
        )
    # render_table() wraps `name` and each `permissions` entry in its OWN
    # literal backticks (`` `{value}` ``); an embedded backtick there
    # closes that code span early and reopens a second one, letting
    # ordinary markdown in between (bold, a link) render live instead of
    # staying literal text - live-demonstrated, round 29. "purpose" is
    # never backtick-wrapped by the template, so an embedded backtick
    # there is just literal prose (CommonMark's code-span rule requires a
    # matching same-length backtick run, so an unpaired one renders as a
    # literal backtick, not an unterminated span swallowing later cells).
    if not allow_backtick and "`" in value:
        raise ValueError(
            f"{catalog_path}: the entry for {_sanitize(name)}'s {field!r} must not contain a backtick "
            "- render_table() wraps this field in its own backticks, and an embedded one would break "
            "out of that code span (see issue #116)."
        )


def load_catalog(catalog_path):
    """Returns the parsed catalog as an ordered `{name: {"purpose": str,
    "permissions": [str, ...]}}` dict (JSON object order is preserved by
    `json.load()`, which is what makes `render_table()`'s output
    deterministic). Raises `ValueError` if the top-level shape or any
    entry's shape does not match, or if a name/purpose/permission string
    contains a character that would corrupt or misrepresent the generated
    table - fails closed rather than rendering a partial or misleading
    table from malformed or adversarial input.
    """
    with open(catalog_path, encoding="utf-8") as handle:
        data = json.load(handle)

    if not isinstance(data, dict):
        raise ValueError(f"{catalog_path} must be a JSON object mapping workflow filenames to entries.")

    for name, entry in data.items():
        # JSON object keys are always strings once json.load() has parsed
        # them, so only the shape of the string itself needs checking here
        # - not its type. A catalog key is a workflow-directory basename,
        # never a path: rejecting "/", "\", and "."/".." keeps
        # os.path.join(workflows_dir, name) in check() from ever escaping
        # that directory for an attacker-chosen key.
        if not name or "/" in name or "\\" in name or name in (".", ".."):
            raise ValueError(
                f"{catalog_path}: {_sanitize(name)!r} is not a valid workflow filename to use as a catalog key."
            )
        _reject_unsafe_cell_text(catalog_path, name, "name", name, allow_backtick=False)

        if not isinstance(entry, dict) or set(entry) != {"purpose", "permissions"}:
            raise ValueError(
                f"{catalog_path}: the entry for {_sanitize(name)} must be an object with exactly "
                '"purpose" and "permissions" keys.'
            )
        if not isinstance(entry["purpose"], str) or not entry["purpose"]:
            raise ValueError(f"{catalog_path}: the entry for {_sanitize(name)} needs a non-empty string \"purpose\".")
        _reject_unsafe_cell_text(catalog_path, name, "purpose", entry["purpose"], allow_backtick=True)

        permissions = entry["permissions"]
        if not isinstance(permissions, list) or not permissions or not all(
            isinstance(p, str) and p for p in permissions
        ):
            raise ValueError(
                f"{catalog_path}: the entry for {_sanitize(name)} needs \"permissions\" as a non-empty "
                "list of non-empty strings."
            )
        for permission in permissions:
            _reject_unsafe_cell_text(catalog_path, name, "permissions", permission, allow_backtick=False)

    return data


def render_table(catalog):
    """Renders the catalog as the exact markdown table text README.md must
    contain between the generated-block markers.
    """
    lines = [_TABLE_HEADER.rstrip("\n")]
    for name, entry in catalog.items():
        permissions = ", ".join(f"`{p}`" for p in entry["permissions"])
        lines.append(f"| `{name}` | {entry['purpose']} | {permissions} |")
    return "\n".join(lines) + "\n"


def _find_marker_span(readme_text):
    """Returns `(content_start, content_end)` for the single generated
    block, or `None` if either marker is missing, out of order, or
    appears more than once. Requiring exactly one of each - not just
    `str.find()`'s first occurrence - closes a real bypass: a second,
    fully attacker-controlled marker-delimited block elsewhere in the
    file used to never be compared to anything, so it passed
    check_freshness() with zero errors while looking just as legitimate
    as the real one (round 28, live-demonstrated).
    """
    if readme_text.count(_BEGIN_MARKER) != 1 or readme_text.count(_END_MARKER) != 1:
        return None
    begin = readme_text.find(_BEGIN_MARKER)
    end = readme_text.find(_END_MARKER)
    if end < begin:
        return None
    return begin + len(_BEGIN_MARKER), end


def check_freshness(readme_path, catalog):
    with open(readme_path, encoding="utf-8") as handle:
        readme_text = handle.read()

    span = _find_marker_span(readme_text)
    if span is None:
        return [
            f"{readme_path} must contain exactly one {_BEGIN_MARKER!r}/{_END_MARKER!r} pair "
            "around the workflow catalog table, in that order - restore or de-duplicate them "
            "(see issue #116)."
        ]
    current = readme_text[span[0] : span[1]]

    expected = "\n" + render_table(catalog) + "\n"
    if current != expected:
        return [
            f"{readme_path}'s workflow catalog table does not match .github/workflow-catalog.json - "
            "regenerate it: `python3 .github/scripts/lib/workflow_catalog.py --write "
            f"{readme_path} .github/workflow-catalog.json` and commit the result (see issue #116)."
        ]
    return []


def write_generated_block(readme_path, catalog):
    """Regenerates the marker-delimited table in place. Not used by CI -
    this is the command a human runs locally after editing the catalog
    JSON, per the message check_freshness() prints.
    """
    with open(readme_path, encoding="utf-8") as handle:
        readme_text = handle.read()

    span = _find_marker_span(readme_text)
    if span is None:
        raise ValueError(
            f"{readme_path} must contain exactly one {_BEGIN_MARKER!r}/{_END_MARKER!r} pair, in "
            "that order - add or de-duplicate them, by hand, before this can regenerate its "
            "contents."
        )

    begin, end = span
    new_text = readme_text[:begin] + "\n" + render_table(catalog) + "\n" + readme_text[end:]
    with open(readme_path, "w", encoding="utf-8") as handle:
        handle.write(new_text)


def check(workflows_dir, readme_path, catalog_path):
    """Returns a list of `::error::`-ready messages (empty if the catalog
    is complete, accurate, and README.md's table matches it): fails closed
    in three directions - every workflow_call target from find_targets()
    must have a catalog entry (issue #101), every catalog entry must still
    name one of those targets (issue #116's reverse direction), and
    README.md's generated block must match what the catalog actually says.
    """
    try:
        catalog = load_catalog(catalog_path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        # No catalog to compare against, so neither the target-completeness
        # nor the freshness check below can run - return immediately rather
        # than cascading into a misleading "every target is undocumented"
        # report, same rationale as the file this replaces.
        return [f"{catalog_path} could not be read: {_sanitize(str(exc))} - fix the file (see issue #116)."]

    errors = []
    targets = list(find_workflow_call_targets.find_targets(workflows_dir))

    for target in targets:
        if target not in catalog:
            errors.append(
                f"{_sanitize(target)} declares workflow_call: but is not listed in "
                f"{catalog_path} - add it (see issue #101)."
            )

    for name in catalog:
        if name in targets:
            continue
        if os.path.isfile(os.path.join(workflows_dir, name)):
            message = (
                "the file exists and declares no workflow_call: trigger the parser could "
                "read - remove the entry or restore the trigger"
            )
        else:
            message = f"the file is missing under {workflows_dir} - remove the entry or restore the file"
        errors.append(f"{_sanitize(name)} is listed in {catalog_path}, but {message} (see issue #116).")

    try:
        errors.extend(check_freshness(readme_path, catalog))
    except (OSError, UnicodeDecodeError) as exc:
        errors.append(f"{readme_path} could not be read: {_sanitize(str(exc))} - fix the file (see issue #116).")

    return errors


def main(argv):
    if len(argv) >= 2 and argv[1] == "--write":
        if len(argv) != 4:
            print("usage: workflow_catalog.py --write <readme_file> <catalog_file>", file=sys.stderr)
            return 2
        try:
            catalog = load_catalog(argv[3])
            write_generated_block(argv[2], catalog)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            print(f"workflow_catalog.py: {_sanitize(str(exc))}", file=sys.stderr)
            return 1
        return 0

    if len(argv) != 4:
        print(
            "usage: workflow_catalog.py <workflows_dir> <readme_file> <catalog_file>\n"
            "       workflow_catalog.py --write <readme_file> <catalog_file>",
            file=sys.stderr,
        )
        return 2

    errors = check(argv[1], argv[2], argv[3])
    for message in errors:
        annotation = f"::error::{message}"
        # See readme_catalog_check.py's own git history for why this
        # encode/decode round-trip exists (surrogate-escaped filenames from
        # find_targets()'s glob() can otherwise crash a UTF-8 stdout).
        print(annotation.encode("utf-8", "backslashreplace").decode("utf-8"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
