import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "lint_adrs", Path(__file__).resolve().parents[1] / "lint-adrs.py")
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


class MarkedADRTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="marked-adr-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.path = self.root / "0001-example.md"
        self.document = """---
documentation_status: needs-review
---

# ADR-0001: Example

- **Status:** accepted
- **Date:** 2026-11-03

## Context
Context.

## Decision
Decision.

## Consequences
Consequences.

## Eject triggers
Triggers.
"""
        LINT._ANCHOR_CACHE.clear()

    def mark(self, text):
        return re.sub(r"[A-Za-z0-9]", lambda match: match[0] + "\U000E0101", text)

    def test_marked_title_metadata_and_sections_pass(self):
        self.path.write_text(self.mark(self.document), encoding="utf-8")
        self.assertEqual(LINT.check(self.path)[0], [])

    def test_marks_do_not_hide_invalid_status(self):
        self.path.write_text(self.mark(self.document.replace("accepted", "unknown")), encoding="utf-8")
        self.assertTrue(any("Status" in problem for problem in LINT.check(self.path)[0]))

    def test_plain_fragments_do_not_resolve_to_marked_headings(self):
        self.path.write_text(self.document + "\n[Decision](target.md#decision)\n", encoding="utf-8")
        (self.root / "target.md").write_text("## " + self.mark("Decision") + "\n", encoding="utf-8")
        with patch.object(LINT, "REPO_ROOT", self.root):
            problems, _ = LINT.check(self.path)
        self.assertTrue(any("link fragment has no matching heading" in problem for problem in problems))

    def test_marked_anchors_match_github_rendered_ids(self):
        fixture = json.loads((Path(__file__).parent / "fixtures" / "github-marked-anchors.json").read_text())
        for example in fixture["headings"]:
            with self.subTest(heading=example["text"]):
                self.assertEqual(LINT.slugify(example["text"]), example["anchor"])

    def test_plain_fragments_resolve_to_plain_headings(self):
        self.path.write_text(self.document + "\n[Decision](target.md#decision)\n", encoding="utf-8")
        (self.root / "target.md").write_text("## Decision\n", encoding="utf-8")
        with patch.object(LINT, "REPO_ROOT", self.root):
            self.assertEqual(LINT.check(self.path)[0], [])

    def test_marked_link_paths_are_rejected_without_repair(self):
        (self.root / "target.md").write_text("## Decision\n", encoding="utf-8")
        self.path.write_text(self.document + "\n[Decision](tar\U000E0101get.md#decision)\n", encoding="utf-8")
        with patch.object(LINT, "REPO_ROOT", self.root):
            problems, _ = LINT.check(self.path)
        self.assertTrue(any("link target contains provenance marks" in problem for problem in problems))

    def test_marked_link_fragments_are_rejected_without_repair(self):
        (self.root / "target.md").write_text("## Decision\n", encoding="utf-8")
        self.path.write_text(self.document + "\n[Decision](target.md#deci\U000E0100sion)\n", encoding="utf-8")
        with patch.object(LINT, "REPO_ROOT", self.root):
            problems, _ = LINT.check(self.path)
        self.assertTrue(any("link target contains provenance marks" in problem for problem in problems))

    def test_marked_link_targets_do_not_create_relationships(self):
        target = self.root / "0002-target.md"
        target.write_text("## Decision\n", encoding="utf-8")
        self.path.write_text(self.document.replace(
            "- **Date:** 2026-11-03",
            "- **Date:** 2026-11-03\n- **Depends on:** [Target](0002-target.md#deci\U000E0101sion)"),
            encoding="utf-8")
        with patch.object(LINT, "REPO_ROOT", self.root):
            problems, relations = LINT.check(self.path)
        self.assertNotIn("Depends on", relations)
        self.assertTrue(any("does not link a local ADR" in problem for problem in problems))
        self.assertTrue(any("link target contains provenance marks" in problem for problem in problems))

    def test_marked_link_examples_in_code_remain_literal(self):
        example = "[Decision](missing\U000E0101.md#deci\U000E0100sion)"
        self.path.write_text(self.document + f"\n`{example}`\n\n```md\n{example}\n```\n", encoding="utf-8")
        self.assertEqual(LINT.check(self.path)[0], [])

    def test_marks_in_a_fence_opener_do_not_hide_visible_sections(self):
        for mark in ("\U000E0100", "\U000E0101"):
            with self.subTest(mark=ascii(mark)):
                self.path.write_text(
                    self.document + f"\n`{mark}``md\n## Decision\n```\n",
                    encoding="utf-8")
                problems, _ = LINT.check(self.path)
                self.assertTrue(any(
                    "required section '## Decision' appears more than once" in problem
                    for problem in problems))

    def test_actual_fences_hide_example_sections_and_links(self):
        for fence in ("```", "~~~"):
            with self.subTest(fence=fence):
                self.path.write_text(
                    self.document + f"\n{fence}md\n## Decision\n[Example](missing.md)\n{fence}\n",
                    encoding="utf-8")
                self.assertEqual(LINT.check(self.path)[0], [])

    def test_vs16_in_a_real_filename_is_preserved(self):
        name = "heart\u2764\ufe0f.md"
        (self.root / name).write_text("## Decision\n", encoding="utf-8")
        self.path.write_text(self.document + f"\n[Decision]({name}#decision)\n", encoding="utf-8")
        with patch.object(LINT, "REPO_ROOT", self.root):
            self.assertEqual(LINT.check(self.path)[0], [])


if __name__ == "__main__":
    unittest.main()
