#!/usr/bin/env python3
# Replaces readme_catalog_check.py's rendered-HTML table extraction (issue
# #101, issue #116) with a generated-artefact model: .github/workflow-catalog.json
# is the source of truth a PR author edits, README.md's catalog table is
# GENERATED from it, and a freshness check (render_table() vs. what is
# actually committed between the markers) is the only thing that ever looks
# at README.md's content. That freshness check is a plain string
# comparison (Python's text-mode file read normalizes line endings, so
# not literally byte-for-byte, but never a markdown/HTML parse either
# way).
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
# as plain text to render_table()'s output. .github/workflow-catalog.json
# is exactly as PR-controlled as README.md ever was, though, so three
# rounds of catalog-VALUE injection findings (a `|`, then raw HTML tags
# and a backtick break-out, one markdown/HTML metacharacter at a time)
# went the same way the old README parser did before it. render_table()
# now renders a raw HTML `<table>` with every value passed through
# `html.escape()`, instead of markdown pipe-table syntax with a
# hand-picked list of forbidden characters - see _reject_unsafe_cell_text()'s
# own comment for why that closes the whole class rather than the one
# construct each prior round was demonstrated with.
#
# find_targets() is imported directly, not invoked as a subprocess - same
# rationale as the file this replaces: producer and consumer are plain
# Python objects in one process, so no NUL-delimited handoff is needed.
import html
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


def _sanitize(text):
    # See readme_catalog_check.py's own _sanitize() history (git log) for
    # why this reuses find_workflow_call_targets._sanitize_for_stderr()
    # rather than a second copy.
    return find_workflow_call_targets._sanitize_for_stderr(text)


def _reject_unsafe_cell_text(catalog_path, name, field, value):
    # render_table() renders a raw HTML <table>, and GitHub's own renderer
    # treats a raw HTML block's content as opaque - never re-parsed as
    # CommonMark/GFM markdown (verified live against GitHub's public
    # Markdown API, 2026-09-07: a markdown link/emphasis/strikethrough/
    # autolink/reference-style-link placed inside a raw <table> renders as
    # inert literal text, not the construct it would be outside one).
    # html.escape() below neutralises `<`, `>` and `&` structurally, so no
    # hand-picked list of dangerous markdown/HTML punctuation (`|`,
    # backtick, the marker strings - each added in its own review round,
    # one construct at a time) is needed here any more. This closes
    # CommonMark/GFM-syntax injection, not every GitHub-specific
    # text-node post-process: as observed on 2026-09-07 against GitHub's
    # rendering, a `#123`-style issue reference, an `@user` mention and a
    # `:emoji:` shortcode inside a raw HTML block were each still rewritten
    # (autolinked/substituted), while the identical text inside a <code>
    # element was left untouched. html.escape() does not neutralise `#`,
    # `@` or `:`, so this is accepted as a narrower, lower-severity residual
    # for "purpose" specifically (name/permissions are always wrapped in
    # <code>, which that pass skips), the same way a plain markdown link in
    # "purpose" already was.
    #
    # What HTML-escaping does NOT fix is anything that isn't a markdown/
    # HTML syntax question in the first place: a Unicode category-C
    # character (Cc/Cf/Cs/Co/Cn - control, format incl. Trojan-Source bidi
    # overrides, surrogate, private-use, unassigned) or a Zl/Zp separator
    # can still end the raw HTML block early at what the parser reads as
    # a blank line. A combining mark (Mn/Mc/Me) is different again: one
    # attached to its base character renders unremarkably, but there is no
    # principled threshold between that and a "Zalgo" stack of dozens, and
    # html.escape() cannot neutralise any of them - so rather than pick an
    # arbitrary cutoff, any occurrence is rejected. All three stay a hard
    # rejection.
    if any(
        unicodedata.category(ch) in ("Zl", "Zp") or unicodedata.category(ch)[0] in ("C", "M") for ch in value
    ):
        raise ValueError(
            f"{catalog_path}: the entry for {_sanitize(name)}'s {field!r} must not contain a Unicode "
            "control, format, separator, or combining-mark character - none of those render safely "
            "in the generated table (see issue #116)."
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
        _reject_unsafe_cell_text(catalog_path, name, "name", name)

        if not isinstance(entry, dict) or set(entry) != {"purpose", "permissions"}:
            raise ValueError(
                f"{catalog_path}: the entry for {_sanitize(name)} must be an object with exactly "
                '"purpose" and "permissions" keys.'
            )
        if not isinstance(entry["purpose"], str) or not entry["purpose"]:
            raise ValueError(f"{catalog_path}: the entry for {_sanitize(name)} needs a non-empty string \"purpose\".")
        _reject_unsafe_cell_text(catalog_path, name, "purpose", entry["purpose"])

        permissions = entry["permissions"]
        if not isinstance(permissions, list) or not permissions or not all(
            isinstance(p, str) and p for p in permissions
        ):
            raise ValueError(
                f"{catalog_path}: the entry for {_sanitize(name)} needs \"permissions\" as a non-empty "
                "list of non-empty strings."
            )
        for permission in permissions:
            _reject_unsafe_cell_text(catalog_path, name, "permissions", permission)

    return data


def _render_purpose(text):
    """Escapes `text` for use as "purpose" cell content, preserving each
    backtick-quoted span (e.g. "Applies ... from `labels.yml`") as a real
    `<code>` element instead of literal backticks. Safe to do by simple
    split-and-wrap, unlike a full markdown parser: CommonMark's code-span
    rule guarantees the text between a MATCHED pair of backticks is
    always literal, never further markdown (no link, no HTML tag, no
    emphasis can activate inside one) - so this introduces no new syntax
    to get wrong, only styling for a span whose own content is escaped
    exactly like the rest of the cell (always from the already-escaped
    list, never the raw text, so a `<`/`>`/`&` inside a span is neutralised
    the same as anywhere else in the cell).

    Backticks are paired greedily, left to right, instead of an
    all-or-nothing fallback: an odd TOTAL count does not mean no span is
    well-formed (e.g. "`b`c`" has one complete pair even though three
    backticks appear overall) - only the one trailing, genuinely
    unmatched backtick (if any) renders as a literal character, and any
    complete pairs before it still become `<code>` elements.

    This pairs individual backtick CHARACTERS, which is a deliberate
    simplification of CommonMark's own rule: real CommonMark matches
    same-length backtick RUNS as a single delimiter, precisely so a
    longer run (e.g. "``") can wrap a span that itself contains a lone
    backtick. A "purpose" value with a run of 2+ consecutive backticks is
    not handled that way here - the backticks inside the run pair up
    with EACH OTHER first (each such pair becomes an empty `<code>`
    element), so the run never acts as one delimiter around the
    surrounding text the way CommonMark would use it. The result is not
    a single fixed shape: "``code``" alone yields two empty `<code>`
    elements with "code" falling out as plain text between them, while a
    run adjacent to an extra lone backtick (e.g. "``foo`bar``") can still
    end up pairing that lone backtick with a run backtick and produce a
    real, non-empty `<code>` element for part of the text - exactly which
    substrings land inside a span depends on the exact backtick count and
    position, not on where the author intended the span to start and end.
    Every substring is still escaped exactly like the rest of the cell
    either way, whichever side of a `<code>` boundary it ends up on.
    """
    parts = text.split("`")
    escaped = [html.escape(part, quote=False) for part in parts]
    pair_count = (len(parts) - 1) // 2

    rendered = [escaped[0]]
    for pair_index in range(pair_count):
        code_part = escaped[2 * pair_index + 1]
        following_text = escaped[2 * pair_index + 2]
        rendered.append(f"<code>{code_part}</code>")
        rendered.append(following_text)

    if (len(parts) - 1) % 2 == 1:
        # A trailing backtick with nothing left to close it - reattach it,
        # literally, along with whatever text followed it.
        rendered.append("`" + "`".join(escaped[2 * pair_count + 1 :]))

    return "".join(rendered)


def render_table(catalog):
    """Renders the catalog as the exact HTML table text README.md must
    contain between the generated-block markers. A raw HTML table, not
    markdown pipe-table syntax - see _reject_unsafe_cell_text()'s own
    comment for why that is what makes html.escape() sufficient here
    instead of a hand-picked list of forbidden markdown characters.
    """
    lines = [
        "<table>",
        "<thead>",
        "<tr><th>Workflow</th><th>Purpose</th><th>Permissions the caller must grant</th></tr>",
        "</thead>",
        "<tbody>",
    ]
    for name, entry in catalog.items():
        # quote=False: every value lands in element TEXT CONTENT, never in
        # an HTML attribute, so a literal quote character needs no
        # escaping - only <, >, and & do, and leaving quotes alone keeps
        # the committed source (e.g. "the caller's own") readable instead
        # of turning every apostrophe into `&#x27;`.
        permissions = ", ".join(f"<code>{html.escape(p, quote=False)}</code>" for p in entry["permissions"])
        lines.append(
            f"<tr><td><code>{html.escape(name, quote=False)}</code></td>"
            f"<td>{_render_purpose(entry['purpose'])}</td>"
            f"<td>{permissions}</td></tr>"
        )
    lines.append("</tbody>")
    lines.append("</table>")
    return "\n".join(lines) + "\n"


def _find_marker_span(readme_text):
    """Returns `(content_start, content_end)` for the single generated
    block, or `None` if either marker is missing, out of order, or
    appears more than once. Requiring exactly one of each - not just
    `str.find()`'s first occurrence - closes a real bypass: a second,
    fully attacker-controlled marker-delimited block elsewhere in the
    file used to never be compared to anything, so it passed
    check_freshness() with zero errors while looking just as legitimate
    as the real one, live-demonstrated.
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
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        # No catalog to compare against, so neither the target-completeness
        # nor the freshness check below can run - return immediately rather
        # than cascading into a misleading "every target is undocumented"
        # report, same rationale as the file this replaces. RecursionError
        # is here alongside JSONDecodeError because json.load() raises it
        # instead for a syntactically valid but pathologically deeply
        # nested document - a PR-controlled catalog file can trigger this,
        # and it should fail closed with one clean message the same way,
        # not crash with a raw traceback.
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
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
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
