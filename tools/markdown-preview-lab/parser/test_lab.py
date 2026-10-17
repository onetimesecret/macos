"""Checks for the test-only XML projection and published-example extractor."""

import sys

sys.dont_write_bytecode = True
import json
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from fixtures import TOKENS, cases
from run import GFMExamples, canonical, html_events

ROOT = Path(__file__).resolve().parent


class LabTests(unittest.TestCase):
    def test_projection_keeps_resource_metadata(self):
        xml = '<link sourcepos="1:1-1:8" destination="https://x/\ufffc"><text xml:space="preserve">label</text></link>'
        self.assertEqual(
            canonical(ET.fromstring(xml)),
            {
                "type": "link",
                "attributes": {"destination": "https://x/\ufffc", "title": ""},
                "children": [{"type": "text", "literal": "label"}],
            },
        )

    def test_projection_keeps_html_as_a_literal(self):
        actual = canonical(
            ET.fromstring('<html_inline>&lt;img src="x"&gt;</html_inline>')
        )
        self.assertEqual(
            actual, {"type": "html_inline", "literal": '<img src="x">'}
        )

    def test_projection_drops_only_empty_text_children(self):
        actual = canonical(
            ET.fromstring(
                '<paragraph><text></text><image destination="x"/><softbreak/></paragraph>'
            )
        )
        self.assertEqual(
            [child["type"] for child in actual["children"]],
            ["image", "softbreak"],
        )

    def test_serializer_equivalence_is_narrow(self):
        self.assertEqual(
            html_events('<input checked="" disabled="" type="checkbox">'),
            html_events('<input type="checkbox" checked="" disabled="" />'),
        )
        self.assertNotEqual(
            html_events("<strong>x</strong>"),
            html_events("<strong><strong>x</strong></strong>"),
        )
        self.assertNotEqual(html_events("<p>a b</p>"), html_events("<p>ab</p>"))

    def test_extracts_displayed_spaces_tabs_and_entities(self):
        parser = GFMExamples()
        parser.feed(
            '<div class="example" id="example-1"><code class="language-markdown"><span class="space"> </span>→&lt;x&gt;\n</code><code class="language-html">&lt;p&gt;x&lt;/p&gt;\n</code></div>'
        )
        self.assertEqual(parser.examples[0]["markdown"], " \t<x>\n")
        self.assertEqual(parser.examples[0]["html"], "<p>x</p>\n")

    def test_full_official_corpora_are_separate(self):
        parser = GFMExamples()
        site = (ROOT / "results/gfm-0.29-spec.html").read_text()
        self.assertIn("Version 0.29-gfm (2019-04-06)", site)
        parser.feed(site)
        self.assertEqual(
            [row["example"] for row in parser.examples], list(range(1, 678))
        )
        cm = json.loads(
            (ROOT / "results/commonmark-0.31.2-spec.json").read_text()
        )
        self.assertEqual(len(cm), 652)

    def test_fixture_matrix_is_complete_and_ids_are_unique(self):
        for dialect in ("commonmark", "gfm"):
            for token in TOKENS:
                matrix = cases(dialect, token)
                self.assertEqual(len(matrix), 45)
                self.assertEqual(len({row["id"] for row in matrix}), 45)
                self.assertTrue(
                    all(TOKENS[token] in row["markdown"] for row in matrix)
                )

    def test_punctuation_expected_outcomes_are_not_shared(self):
        def expected(dialect, spelling, name):
            return next(
                row["expected_ast"]
                for row in cases(dialect, spelling)
                if row["id"] == name
            )

        for name in (
            "underscore-after",
            "underscore-before",
            "underscore-both",
            "star-interior",
        ):
            self.assertNotEqual(
                expected("commonmark", "so", name), expected("gfm", "so", name)
            )
            self.assertEqual(
                expected("commonmark", "ascii", name),
                expected("gfm", "ascii", name),
            )


if __name__ == "__main__":
    unittest.main()
