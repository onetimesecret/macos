import copy
import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_document_types", ROOT / "scripts" / "check-document-types.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class DocumentTypeTests(unittest.TestCase):
    def setUp(self):
        with open(ROOT / "shell" / "OnetimePad-Info.plist", "rb") as handle:
            self.plist = plistlib.load(handle)

    def test_the_source_plist_passes(self):
        self.assertEqual(CHECK.problems(self.plist), [])

    def test_a_changed_rank_is_reported(self):
        plist = copy.deepcopy(self.plist)
        plist["CFBundleDocumentTypes"][0]["LSHandlerRank"] = "Owner"
        self.assertTrue(any("ranks" in line for line in CHECK.problems(plist)))

    def test_a_document_class_is_reported(self):
        plist = copy.deepcopy(self.plist)
        plist["CFBundleDocumentTypes"][1]["NSDocumentClass"] = "Document"
        self.assertTrue(any("NSDocumentClass" in line for line in CHECK.problems(plist)))

    def test_a_dropped_import_is_reported(self):
        plist = copy.deepcopy(self.plist)
        del plist["UTImportedTypeDeclarations"]
        self.assertTrue(any("not imported" in line for line in CHECK.problems(plist)))


if __name__ == "__main__":
    unittest.main()
