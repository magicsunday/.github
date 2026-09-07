#!/usr/bin/env python3
# Exercises workflow_catalog.py - the generated-artefact replacement for
# readme_catalog_check.py's rendered-HTML table extraction (issue #101,
# issue #116). Unlike its predecessor, this module never parses README.md's
# markdown/HTML - the freshness check is a plain string comparison against
# render_table()'s own output, so there is no decoy/nesting/homoglyph
# construct to pin fixtures against here; the fixtures instead cover the
# JSON schema's failure modes and the freshness comparison's edge cases.
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib", "workflow_catalog.py"
)
_spec = importlib.util.spec_from_file_location("workflow_catalog", _MODULE_PATH)
assert _spec is not None and _spec.loader is not None
workflow_catalog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(workflow_catalog)

_ONE_ENTRY_CATALOG = {"real.yml": {"purpose": "Does the real thing", "permissions": ["contents: read"]}}


class _TempRepoTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.work_dir = self._tmp.name
        self.workflows_dir = os.path.join(self.work_dir, "workflows")
        os.makedirs(self.workflows_dir)
        self.readme_path = os.path.join(self.work_dir, "README.md")
        self.catalog_path = os.path.join(self.work_dir, "workflow-catalog.json")

    def _add_target(self, name, workflow_call=True):
        with open(os.path.join(self.workflows_dir, name), "w", encoding="utf-8") as handle:
            handle.write("on:\n    workflow_call:\n" if workflow_call else "on:\n    push:\n")

    def _write_catalog(self, catalog):
        with open(self.catalog_path, "w", encoding="utf-8") as handle:
            json.dump(catalog, handle)

    def _write_readme(self, text):
        with open(self.readme_path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def _write_fresh_readme(self, catalog):
        self._write_readme(
            "# Title\n\n"
            "<!-- workflow-catalog:start -->\n"
            + workflow_catalog.render_table(catalog)
            + "\n<!-- workflow-catalog:end -->\n\nTrailing prose.\n"
        )

    def _check(self):
        return workflow_catalog.check(self.workflows_dir, self.readme_path, self.catalog_path)


class LoadCatalogTest(_TempRepoTestCase):
    def test_well_formed_catalog_loads(self):
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self.assertEqual(workflow_catalog.load_catalog(self.catalog_path), _ONE_ENTRY_CATALOG)

    def test_order_is_preserved(self):
        catalog = {
            "b.yml": {"purpose": "B", "permissions": ["contents: read"]},
            "a.yml": {"purpose": "A", "permissions": ["contents: read"]},
        }
        self._write_catalog(catalog)
        self.assertEqual(list(workflow_catalog.load_catalog(self.catalog_path)), ["b.yml", "a.yml"])

    def test_top_level_must_be_an_object(self):
        self._write_catalog(["not", "an", "object"])
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_entry_that_is_not_an_object_is_rejected(self):
        # A JSON array happens to have a key-set (via set() on its
        # elements) that could equal {"purpose", "permissions"} for some
        # inputs - the isinstance check is what actually catches this
        # shape, not the key-set comparison.
        self._write_catalog({"real.yml": ["purpose", "permissions"]})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_entry_missing_permissions_key_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x"}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_entry_with_an_extra_key_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": ["contents: read"], "extra": 1}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_empty_purpose_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_non_string_purpose_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": 123, "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_permissions_must_be_a_list_not_a_bare_string(self):
        # A bare string is iterable character-by-character - exactly the
        # trap a `permissions: "contents: read"` typo would fall into
        # without this check.
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": "contents: read"}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_empty_permissions_list_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": []}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_empty_string_permission_entry_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": ["contents: read", ""]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_non_string_permission_entry_is_rejected(self):
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": [123]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_pipe_in_purpose_is_allowed(self):
        # render_table() renders a raw HTML table, not markdown pipe-table
        # syntax, so a `|` cannot splice an extra column any more - it is
        # ordinary text render_table() passes to html.escape() unchanged
        # (html.escape() does not touch `|`).
        self._write_catalog({"real.yml": {"purpose": "Does X | still one cell", "permissions": ["contents: read"]}})
        workflow_catalog.load_catalog(self.catalog_path)  # must not raise

    def test_embedded_newline_in_purpose_is_rejected(self):
        # A newline can end the enclosing raw HTML block early at what the
        # parser reads as a blank line, pushing the real remaining cells
        # into unrelated rendered prose - html.escape() does not touch
        # control characters, only `<`/`>`/`&`, so this stays a hard
        # rejection rather than something escaping can absorb.
        self._write_catalog({"real.yml": {"purpose": "Fine.\n\n**Also grant admin.**", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_bidi_override_character_in_purpose_is_rejected(self):
        # U+202E RIGHT-TO-LEFT OVERRIDE - a Trojan-Source-style character
        # that is not a `|` and not a C0/C1 control character, but is
        # still Unicode category "Cf" (format).
        self._write_catalog({"real.yml": {"purpose": "Normal ‮reversed", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_single_combining_mark_in_purpose_is_rejected(self):
        # The guard rejects ANY occurrence of a combining mark, not only a
        # long "Zalgo" run - a single one (e.g. from NFD-normalized "é"
        # spelled as "e" + a combining acute accent) is already enough.
        self._write_catalog({"real.yml": {"purpose": "cafe" + "́", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_combining_marks_in_purpose_are_rejected(self):
        # A long run of combining marks ("Zalgo" text) visually distorts
        # or obscures a cell - html.escape() does not touch these either,
        # so they stay a hard rejection alongside the other Unicode
        # categories above.
        self._write_catalog({"real.yml": {"purpose": "z" + ("́" * 50), "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_marker_text_embedded_in_purpose_is_now_safely_escaped(self):
        # render_table() html.escape()'s every value, so embedding the
        # literal marker text renders as inert escaped text instead of the
        # literal marker string - it can no longer confuse a later
        # --write's marker count the way it could before escaping existed.
        catalog = {"real.yml": {"purpose": "x <!-- workflow-catalog:end --> y", "permissions": ["contents: read"]}}
        self._write_catalog(catalog)
        loaded = workflow_catalog.load_catalog(self.catalog_path)  # must not raise
        table = workflow_catalog.render_table(loaded)
        self.assertIn("x &lt;!-- workflow-catalog:end --&gt; y", table)
        self.assertNotIn("<!-- workflow-catalog:end -->", table)

    def test_raw_html_tag_in_purpose_is_now_safely_escaped(self):
        # `<`/`>` used to let a value construct raw HTML tags that forged
        # a sibling table row/column; render_table() now emits a raw HTML
        # table with every value passed through html.escape(), which
        # turns `<`/`>` into inert `&lt;`/`&gt;` text instead of real tag
        # delimiters - verified live against GitHub's own renderer,
        # 2026-09-07.
        catalog = {"real.yml": {"purpose": "x</td><td>not forged</td><td>y", "permissions": ["contents: read"]}}
        self._write_catalog(catalog)
        loaded = workflow_catalog.load_catalog(self.catalog_path)  # must not raise
        table = workflow_catalog.render_table(loaded)
        self.assertIn("x&lt;/td&gt;&lt;td&gt;not forged&lt;/td&gt;&lt;td&gt;y", table)
        self.assertNotIn("</td><td>not forged", table)

    def test_backtick_in_the_catalog_key_is_now_safely_escaped(self):
        # render_table() wraps name/permissions in a real <code> element,
        # not markdown backtick syntax, so an embedded backtick is just
        # ordinary (html.escape()d) text now - no code-span to break out
        # of any more.
        catalog = {"x` **not a breakout** `y.yml": {"purpose": "x", "permissions": ["contents: read"]}}
        self._write_catalog(catalog)
        loaded = workflow_catalog.load_catalog(self.catalog_path)  # must not raise
        table = workflow_catalog.render_table(loaded)
        self.assertIn("<code>x` **not a breakout** `y.yml</code>", table)
        self.assertNotIn("<strong>", table)

    def test_backtick_in_purpose_is_still_allowed(self):
        self._write_catalog({"real.yml": {"purpose": "Uses `make lang`", "permissions": ["contents: read"]}})
        workflow_catalog.load_catalog(self.catalog_path)  # must not raise

    def test_line_separator_character_in_purpose_is_rejected(self):
        # U+2028 LINE SEPARATOR - Unicode category "Zl", not covered by
        # the category-C check alone.
        self._write_catalog({"real.yml": {"purpose": "Normal separated", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_paragraph_separator_character_in_purpose_is_rejected(self):
        # U+2029 PARAGRAPH SEPARATOR - Unicode category "Zp", the sibling
        # of "Zl" tested above; both end up in the same ("Zl", "Zp") tuple
        # in the guard, but neither test exercises the other's branch.
        self._write_catalog({"real.yml": {"purpose": "Normal separated", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_bidi_override_character_in_the_catalog_key_is_rejected(self):
        # The Unicode-category guard runs on every field load_catalog()
        # passes through it, not only "purpose" - a catalog key is just as
        # capable of carrying a Trojan-Source-style override character.
        self._write_catalog({"real‮.yml": {"purpose": "x", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_bidi_override_character_in_a_permission_is_rejected(self):
        # Same guard, same reasoning, for the third field it is called on:
        # a permission string is rendered via plain html.escape() (never
        # _render_purpose()'s backtick handling), so it relies entirely on
        # this rejection to keep a bidi override out of the table.
        self._write_catalog({"real.yml": {"purpose": "x", "permissions": ["contents: ‮read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_slash_in_the_catalog_key_is_rejected(self):
        self._write_catalog({"../../etc/passwd": {"purpose": "x", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_backslash_in_the_catalog_key_is_rejected(self):
        self._write_catalog({"sub\\real.yml": {"purpose": "x", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_empty_string_catalog_key_is_rejected(self):
        self._write_catalog({"": {"purpose": "x", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_dot_dot_as_the_catalog_key_is_rejected(self):
        self._write_catalog({"..": {"purpose": "x", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_single_dot_as_the_catalog_key_is_rejected(self):
        self._write_catalog({".": {"purpose": "x", "permissions": ["contents: read"]}})
        with self.assertRaises(ValueError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_malformed_json_raises(self):
        self._write_readme("")  # unrelated, just to have the dir populated
        with open(self.catalog_path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        with self.assertRaises(json.JSONDecodeError):
            workflow_catalog.load_catalog(self.catalog_path)

    def test_missing_file_raises(self):
        with self.assertRaises(OSError):
            workflow_catalog.load_catalog(self.catalog_path)


class RenderTableTest(unittest.TestCase):
    def test_single_entry(self):
        table = workflow_catalog.render_table(_ONE_ENTRY_CATALOG)
        self.assertEqual(
            table,
            "<table>\n"
            "<thead>\n"
            "<tr><th>Workflow</th><th>Purpose</th><th>Permissions the caller must grant</th></tr>\n"
            "</thead>\n"
            "<tbody>\n"
            "<tr><td><code>real.yml</code></td><td>Does the real thing</td>"
            "<td><code>contents: read</code></td></tr>\n"
            "</tbody>\n"
            "</table>\n",
        )

    def test_multiple_permissions_are_each_a_code_element_comma_joined(self):
        catalog = {"real.yml": {"purpose": "x", "permissions": ["contents: read", "issues: write"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("<code>contents: read</code>, <code>issues: write</code>", table)

    def test_row_order_follows_catalog_order(self):
        catalog = {
            "b.yml": {"purpose": "B", "permissions": ["contents: read"]},
            "a.yml": {"purpose": "A", "permissions": ["contents: read"]},
        }
        table = workflow_catalog.render_table(catalog)
        self.assertLess(table.index("b.yml"), table.index("a.yml"))

    def test_purpose_backtick_span_becomes_a_real_code_element(self):
        # A matched backtick pair in "purpose" keeps its intended styling
        # as a real <code> element instead of rendering as two literal
        # backtick characters, now that the surrounding raw HTML block is
        # never re-parsed as markdown.
        catalog = {
            "real.yml": {
                "purpose": "Uses `make lang` — see below",
                "permissions": ["contents: read"],
            }
        }
        table = workflow_catalog.render_table(catalog)
        self.assertIn("Uses <code>make lang</code> — see below", table)

    def test_purpose_em_dash_passes_through_unescaped(self):
        # An em-dash is not a markdown/HTML metacharacter - html.escape()
        # only touches `<`, `>`, `&`, and (with quote=False, not used
        # here) quote characters.
        catalog = {"real.yml": {"purpose": "See below — for details", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("See below — for details", table)

    def test_purpose_unpaired_backtick_stays_literal(self):
        # An odd number of backticks has no matching close, mirroring
        # CommonMark's own code-span rule: it renders as a literal
        # character rather than an unterminated span.
        catalog = {"real.yml": {"purpose": "an unmatched ` backtick", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("<td>an unmatched ` backtick</td>", table)

    def test_purpose_two_separate_backtick_pairs_both_become_code_elements(self):
        # Exercises the pairing loop across more than one iteration (the
        # 2*pair_index+1/+2 index arithmetic). The trailing unmatched
        # backtick makes the total count odd, so this also discriminates
        # the greedy-pairing fix from the old total-count-parity fallback:
        # that older code would have rendered this whole string literally.
        catalog = {"real.yml": {"purpose": "Uses `foo` and `bar` also`", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("<td>Uses <code>foo</code> and <code>bar</code> also`</td>", table)

    def test_purpose_odd_backtick_count_still_pairs_the_leading_span(self):
        # A trailing, genuinely unmatched backtick does not erase a
        # complete pair earlier in the same string - pairing greedily from
        # the left, not by total-backtick-count parity, is what gets this
        # right.
        catalog = {"real.yml": {"purpose": "a `b`c`d", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("<td>a <code>b</code>c`d</td>", table)

    def test_purpose_code_span_content_is_itself_html_escaped(self):
        # Guards against a regression that inlines the raw split segment
        # instead of the already-html.escape()d one - would slip an
        # unescaped `<script>` into the rendered <code> element.
        catalog = {"real.yml": {"purpose": "Uses `<script>`", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("<td>Uses <code>&lt;script&gt;</code></td>", table)
        self.assertNotIn("<code><script>", table)

    def test_purpose_doubled_backtick_produces_empty_code_elements(self):
        # A run of 2+ consecutive backticks pairs with itself rather than
        # acting as one CommonMark-style delimiter around the surrounding
        # text (see _render_purpose()'s own docstring): each internal
        # pair becomes an EMPTY <code> element, and the text the author
        # meant to style falls out as plain (still escaped) content
        # between them, rather than staying styled.
        catalog = {"real.yml": {"purpose": "a ``code`` b", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("<td>a <code></code>code<code></code> b</td>", table)

    def test_apostrophe_is_not_escaped_since_quote_is_false(self):
        catalog = {"real.yml": {"purpose": "Uses the caller's own token", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("the caller's own token", table)
        self.assertNotIn("&#x27;", table)

    def test_catalog_key_angle_brackets_are_escaped(self):
        catalog = {"x</td><td>y.yml": {"purpose": "p", "permissions": ["contents: read"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("x&lt;/td&gt;&lt;td&gt;y.yml", table)
        self.assertNotIn("</td><td>y.yml<", table)

    def test_permission_entry_angle_brackets_are_escaped(self):
        catalog = {"real.yml": {"purpose": "p", "permissions": ["contents: read</td><td>forged"]}}
        table = workflow_catalog.render_table(catalog)
        self.assertIn("contents: read&lt;/td&gt;&lt;td&gt;forged", table)
        self.assertNotIn("</td><td>forged", table)

    def test_angle_brackets_and_ampersand_are_html_escaped(self):
        catalog = {
            "real.yml": {
                "purpose": "a</td><td>b & c",
                "permissions": ["contents: read"],
            }
        }
        table = workflow_catalog.render_table(catalog)
        self.assertIn("a&lt;/td&gt;&lt;td&gt;b &amp; c", table)
        self.assertNotIn("a</td><td>b & c", table)


class CheckFreshnessTest(_TempRepoTestCase):
    def test_matching_content_has_no_errors(self):
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        self.assertEqual(workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG), [])

    def test_missing_begin_marker_is_reported(self):
        self._write_readme("no markers here\n<!-- workflow-catalog:end -->\n")
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("exactly one", errors[0])

    def test_missing_end_marker_is_reported(self):
        self._write_readme("<!-- workflow-catalog:start -->\nno end marker\n")
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("exactly one", errors[0])

    def test_end_marker_before_begin_marker_is_treated_as_missing(self):
        self._write_readme("<!-- workflow-catalog:end -->\n...\n<!-- workflow-catalog:start -->\n")
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("exactly one", errors[0])

    def test_stale_table_is_reported_with_the_regen_command(self):
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        stale_catalog = {
            "real.yml": {"purpose": "Does the real thing", "permissions": ["contents: read"]},
            "extra.yml": {"purpose": "New", "permissions": ["contents: read"]},
        }
        errors = workflow_catalog.check_freshness(self.readme_path, stale_catalog)
        self.assertEqual(len(errors), 1)
        self.assertIn("workflow_catalog.py --write", errors[0])

    def test_a_single_extra_trailing_space_is_flagged(self):
        # The comparison is byte-exact, not whitespace-tolerant - a manual
        # hand-edit of the generated block (rather than running --write)
        # must still be caught.
        self._write_readme(
            "<!-- workflow-catalog:start -->\n" + workflow_catalog.render_table(_ONE_ENTRY_CATALOG) + " \n"
            "<!-- workflow-catalog:end -->\n"
        )
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)

    def test_a_second_marker_pair_is_never_silently_ignored(self):
        # str.find() alone only ever locates the FIRST occurrence of each
        # marker - a second, fully attacker-controlled marker-delimited
        # block used to pass with zero errors since nothing ever compared
        # it to anything.
        self._write_readme(
            "<!-- workflow-catalog:start -->\n"
            + workflow_catalog.render_table(_ONE_ENTRY_CATALOG)
            + "\n<!-- workflow-catalog:end -->\n\n"
            "<!-- workflow-catalog:start -->\n"
            "| Workflow | Purpose | Permissions the caller must grant |\n"
            "| --- | --- | --- |\n"
            "| `real.yml` | Forged | `contents: write` |\n"
            "\n<!-- workflow-catalog:end -->\n"
        )
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("exactly one", errors[0])

    def test_a_duplicated_end_marker_alone_is_never_silently_ignored(self):
        # The begin/end counts are two independent `!= 1` checks - a
        # duplicate on the END side alone is a distinct branch from the
        # "both markers duplicated together" case above.
        self._write_readme(
            "<!-- workflow-catalog:start -->\n"
            + workflow_catalog.render_table(_ONE_ENTRY_CATALOG)
            + "\n<!-- workflow-catalog:end -->\n\n<!-- workflow-catalog:end -->\n"
        )
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("exactly one", errors[0])

    def test_a_duplicated_begin_marker_alone_is_never_silently_ignored(self):
        # Mirror of the END-alone case above: the begin count is checked
        # independently of the end count, so a second, attacker-controlled
        # begin marker paired with a single legitimate end marker must not
        # slip through either.
        self._write_readme(
            "<!-- workflow-catalog:start -->\n\n<!-- workflow-catalog:start -->\n"
            + workflow_catalog.render_table(_ONE_ENTRY_CATALOG)
            + "\n<!-- workflow-catalog:end -->\n"
        )
        errors = workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(len(errors), 1)
        self.assertIn("exactly one", errors[0])


class WriteGeneratedBlockTest(_TempRepoTestCase):
    def test_regenerates_the_block_in_place(self):
        self._write_readme(
            "Intro.\n\n<!-- workflow-catalog:start -->\nstale content\n<!-- workflow-catalog:end -->\n\nOutro.\n"
        )
        workflow_catalog.write_generated_block(self.readme_path, _ONE_ENTRY_CATALOG)
        self.assertEqual(workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG), [])

    def test_content_outside_the_markers_is_untouched(self):
        self._write_readme(
            "Intro paragraph.\n\n<!-- workflow-catalog:start -->\nstale\n<!-- workflow-catalog:end -->\n\n"
            "Outro paragraph.\n"
        )
        workflow_catalog.write_generated_block(self.readme_path, _ONE_ENTRY_CATALOG)
        with open(self.readme_path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("Intro paragraph.", text)
        self.assertIn("Outro paragraph.", text)

    def test_missing_markers_raises_instead_of_silently_appending(self):
        self._write_readme("No markers at all.\n")
        with self.assertRaises(ValueError):
            workflow_catalog.write_generated_block(self.readme_path, _ONE_ENTRY_CATALOG)

    def test_duplicated_markers_raise_instead_of_regenerating_the_wrong_pair(self):
        self._write_readme(
            "<!-- workflow-catalog:start -->\nstale\n<!-- workflow-catalog:end -->\n\n"
            "<!-- workflow-catalog:start -->\nstale too\n<!-- workflow-catalog:end -->\n"
        )
        with self.assertRaises(ValueError):
            workflow_catalog.write_generated_block(self.readme_path, _ONE_ENTRY_CATALOG)


class CheckTest(_TempRepoTestCase):
    def test_fully_documented_and_fresh_catalog_passes(self):
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        self.assertEqual(self._check(), [])

    def test_missing_readme_reports_one_message_not_a_crash(self):
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        # self.readme_path is never created.
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_undocumented_target_fails(self):
        self._add_target("real.yml")
        self._write_catalog({})
        self._write_fresh_readme({})
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("real.yml", errors[0])
        self.assertIn("issue #101", errors[0])

    def test_stale_entry_for_removed_file_fails(self):
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("is missing", errors[0])

    def test_stale_entry_for_de_reusabled_file_names_the_cause(self):
        self._add_target("real.yml", workflow_call=False)
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("declares no workflow_call", errors[0])

    def test_malformed_catalog_reports_one_message_not_a_cascade(self):
        self._add_target("real.yml")
        with open(self.catalog_path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        self._write_readme("<!-- workflow-catalog:start -->\n<!-- workflow-catalog:end -->\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_missing_catalog_file_reports_one_message(self):
        self._add_target("real.yml")
        self._write_readme("<!-- workflow-catalog:start -->\n<!-- workflow-catalog:end -->\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_catalog_with_invalid_utf8_bytes_reports_could_not_be_read(self):
        # load_catalog() opens the catalog with encoding="utf-8" - a byte
        # sequence that isn't valid UTF-8 raises UnicodeDecodeError, which
        # check() catches alongside OSError/JSONDecodeError/ValueError so
        # this reports the same clean message instead of an unhandled
        # traceback.
        self._add_target("real.yml")
        with open(self.catalog_path, "wb") as handle:
            handle.write(b"{\"real.yml\": \"\xff\xfe\"}")
        self._write_readme("<!-- workflow-catalog:start -->\n<!-- workflow-catalog:end -->\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_readme_with_invalid_utf8_bytes_reports_could_not_be_read(self):
        # Mirror of the catalog case above for check_freshness()'s own
        # open(readme_path, encoding="utf-8") call.
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        with open(self.readme_path, "wb") as handle:
            handle.write(b"<!-- workflow-catalog:start -->\xff\xfe<!-- workflow-catalog:end -->")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("could not be read", errors[0])

    def test_independent_failures_in_different_directions_all_accumulate(self):
        # check()'s own docstring says it fails closed in three
        # independent directions - this pins that they actually
        # ACCUMULATE into one list rather than short-circuiting after the
        # first one found, which every other test here (each with exactly
        # one failure) cannot distinguish from a fail-fast implementation.
        self._add_target("real.yml")  # undocumented: not in the catalog below
        stale_catalog = {"removed.yml": {"purpose": "Does the real thing", "permissions": ["contents: read"]}}
        self._write_catalog(stale_catalog)
        self._write_fresh_readme(stale_catalog)
        errors = self._check()
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("real.yml" in e and "issue #101" in e for e in errors))
        self.assertTrue(any("removed.yml" in e and "is missing" in e for e in errors))

    def test_catalog_and_targets_agree_but_readme_is_stale(self):
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_readme("<!-- workflow-catalog:start -->\nstale\n<!-- workflow-catalog:end -->\n")
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("does not match", errors[0])

    def test_forward_direction_sanitizes_a_target_filename_with_an_embedded_newline(self):
        self._add_target("real\r\x0a.yml")
        self._write_catalog({})
        self._write_fresh_readme({})
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertNotIn("\n", errors[0])

    def test_reverse_direction_sanitizes_a_percent_sign_in_a_stale_entry_name(self):
        self._write_catalog({"100%.yml": {"purpose": "x", "permissions": ["contents: read"]}})
        self._write_fresh_readme({"100%.yml": {"purpose": "x", "permissions": ["contents: read"]}})
        errors = self._check()
        self.assertEqual(len(errors), 1)
        self.assertIn("100%25.yml", errors[0])


class MainTest(_TempRepoTestCase):
    def _run_main(self, argv):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = workflow_catalog.main(["workflow_catalog.py"] + argv)
        return code, stdout.getvalue()

    def test_usage_error_on_wrong_argc(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = workflow_catalog.main(["workflow_catalog.py", "only-one-arg"])
        self.assertEqual(code, 2)
        self.assertIn("usage:", stderr.getvalue())

    def test_returns_zero_for_a_complete_and_fresh_catalog(self):
        self._add_target("real.yml")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        self._write_fresh_readme(_ONE_ENTRY_CATALOG)
        code, out = self._run_main([self.workflows_dir, self.readme_path, self.catalog_path])
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_returns_one_and_prints_an_annotation_for_an_incomplete_catalog(self):
        self._add_target("real.yml")
        self._write_catalog({})
        self._write_fresh_readme({})
        code, out = self._run_main([self.workflows_dir, self.readme_path, self.catalog_path])
        self.assertEqual(code, 1)
        self.assertIn("::error::", out)

    def test_write_mode_usage_error_on_wrong_argc(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = workflow_catalog.main(["workflow_catalog.py", "--write", self.readme_path])
        self.assertEqual(code, 2)
        self.assertIn("--write <readme_file> <catalog_file>", stderr.getvalue())

    def test_write_mode_regenerates_and_returns_zero(self):
        self._write_readme("<!-- workflow-catalog:start -->\nstale\n<!-- workflow-catalog:end -->\n")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        code, _ = self._run_main(["--write", self.readme_path, self.catalog_path])
        self.assertEqual(code, 0)
        self.assertEqual(workflow_catalog.check_freshness(self.readme_path, _ONE_ENTRY_CATALOG), [])

    def test_write_mode_reports_missing_markers_on_stderr_and_returns_one(self):
        self._write_readme("no markers\n")
        self._write_catalog(_ONE_ENTRY_CATALOG)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = workflow_catalog.main(["workflow_catalog.py", "--write", self.readme_path, self.catalog_path])
        self.assertEqual(code, 1)
        self.assertIn("exactly one", stderr.getvalue())

    def test_non_utf8_workflow_filename_does_not_crash_the_annotation_print(self):
        # Mirrors readme_catalog_check.py's identical regression test: a
        # workflow filename decoded from raw POSIX bytes via glob()'s
        # surrogateescape can carry a lone surrogate codepoint into an
        # ::error:: annotation. main() protects the print() with an
        # encode/decode round-trip specifically because the real stdout
        # GitHub Actions gives the job is strictly UTF-8 - an io.StringIO()
        # capture (what _run_main() uses for every other test here) never
        # encodes to bytes at all, so it cannot exercise that crash path;
        # this test needs its own real UTF-8-strict encoding boundary.
        bad_name = os.fsencode("real-\udcff.yml")
        with open(os.path.join(self.workflows_dir, os.fsdecode(bad_name)), "w", encoding="utf-8", errors="surrogateescape") as handle:
            handle.write("on:\n    workflow_call:\n")
        self._write_catalog({})
        self._write_fresh_readme({})
        buf = io.BytesIO()
        wrapper = io.TextIOWrapper(buf, encoding="utf-8", errors="strict")
        with contextlib.redirect_stdout(wrapper):
            code = workflow_catalog.main(
                ["workflow_catalog.py", self.workflows_dir, self.readme_path, self.catalog_path]
            )
            wrapper.flush()
        out = buf.getvalue().decode("utf-8")
        self.assertEqual(code, 1)
        self.assertIn("::error::", out)


if __name__ == "__main__":
    unittest.main()
