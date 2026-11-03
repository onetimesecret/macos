import importlib.util
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
        self.root = Path(temporary.name)
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

    def test_links_to_marked_headings_resolve(self):
        self.path.write_text(self.document + "\n[Decision](target.md#decision)\n", encoding="utf-8")
        (self.root / "target.md").write_text("## " + self.mark("Decision") + "\n", encoding="utf-8")
        with patch.object(LINT, "REPO_ROOT", self.root):
            self.assertEqual(LINT.check(self.path)[0], [])


if __name__ == "__main__":
    unittest.main()
