#!/usr/bin/env python3
"""Offline AST regressions and independent official-corpus HTML comparisons."""

import sys

sys.dont_write_bytecode = True
import datetime
import hashlib
import json
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

from fixtures import TOKENS, cases

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "results"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def invoke(dialect, mode, source=""):
    command = [str(ROOT / f"build/{dialect}-parser"), mode]
    result = subprocess.run(
        command, input=source, text=True, capture_output=True, timeout=10
    )
    if result.returncode:
        raise RuntimeError(f"{command}: {result.returncode}: {result.stderr}")
    return result.stdout


def canonical(element):
    kind = element.tag.rsplit("}", 1)[-1]
    value = {"type": kind}
    attributes = {
        key.rsplit("}", 1)[-1]: val
        for key, val in element.attrib.items()
        if key.rsplit("}", 1)[-1] not in ("sourcepos", "space")
    }
    if kind in ("link", "image"):
        attributes.setdefault("title", "")
    if attributes:
        value["attributes"] = attributes
    if kind in ("text", "html_inline", "html_block", "code", "code_block"):
        value["literal"] = element.text or ""
    children = [canonical(child) for child in element]
    children = [
        child for child in children if child != {"type": "text", "literal": ""}
    ]
    if children:
        value["children"] = children
    return value


def locations(node, token, path="document"):
    found = []
    for key in ("literal",):
        if token in node.get(key, ""):
            found.append(
                {"path": path + "." + key, "count": node[key].count(token)}
            )
    for key, value in node.get("attributes", {}).items():
        if token in value:
            found.append(
                {
                    "path": path + ".attributes." + key,
                    "count": value.count(token),
                }
            )
    for index, child in enumerate(node.get("children", [])):
        found.extend(
            locations(child, token, path + f"/{index}:{child['type']}")
        )
    return found


class GFMExamples(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.examples = []
        self.current = None
        self.language = None
        self.section = ""
        self.heading = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("h2", "h3"):
            self.heading = []
        if tag == "div" and attrs.get("class") == "example":
            self.current = {
                "example": int(attrs["id"].removeprefix("example-")),
                "section": self.section,
            }
        if tag == "code" and self.current:
            language = attrs.get("class", "")
            if language in ("language-markdown", "language-html"):
                self.language = (
                    "markdown" if language == "language-markdown" else "html"
                )
                self.current[self.language] = ""

    def handle_endtag(self, tag):
        if tag in ("h2", "h3") and self.heading is not None:
            self.section = "".join(self.heading).strip()
            self.heading = None
        if tag == "code" and self.language:
            self.language = None
            if "html" in self.current:
                self.examples.append(self.current)
                self.current = None

    def handle_data(self, data):
        if self.heading is not None:
            self.heading.append(data)
        if self.language:
            self.current[self.language] += data.replace("→", "\t")


class HTMLEvents(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.events = []

    def handle_starttag(self, tag, attrs):
        self.events.append(["start", tag, sorted(attrs)])

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in (
            "area",
            "base",
            "br",
            "col",
            "embed",
            "hr",
            "img",
            "input",
            "link",
            "meta",
            "param",
            "source",
            "track",
            "wbr",
        ):
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        self.events.append(["end", tag])

    def handle_data(self, data):
        if self.events and self.events[-1][0] == "data":
            self.events[-1][1] += data
        else:
            self.events.append(["data", data])

    def handle_comment(self, data):
        self.events.append(["comment", data])


def html_events(source):
    parser = HTMLEvents()
    parser.feed(source)
    return parser.events


def corpus(dialect, examples):
    records = []
    for example in examples:
        actual = invoke(dialect, "--html", example["markdown"])
        records.append(
            {
                "example": example["example"],
                "section": example["section"],
                "markdown": example["markdown"],
                "expected_html": example["html"],
                "actual_html": actual,
                "equal": actual == example["html"],
                "html_event_equal": html_events(actual)
                == html_events(example["html"]),
            }
        )
    for record in records:
        if not record["equal"] and dialect != "commonmark":
            core = invoke(dialect, "--html-core", record["markdown"])
            record["extensions_disabled_html"] = core
            record["extensions_disabled_equal"] = (
                core == record["expected_html"]
            )
    with (RESULTS / f"{dialect}-corpus-results.jsonl").open("w") as output:
        for record in records:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
    return {
        "total": len(records),
        "exact_html_passed": sum(row["equal"] for row in records),
        "html_event_passed": sum(row["html_event_equal"] for row in records),
        "serializer_only_ids": [
            row["example"]
            for row in records
            if not row["equal"] and row["html_event_equal"]
        ],
        "extensions_disabled_match_ids": [
            row["example"]
            for row in records
            if row.get("extensions_disabled_equal")
        ],
        "mismatches": [row for row in records if not row["equal"]],
    }


def main():
    provenance = json.loads((RESULTS / "provenance.json").read_text())
    assert sha(ROOT / "harness.c") == provenance["harness_sha256"], (
        "Rebuild the changed C harness"
    )
    for dialect in ("commonmark", "gfm", "gfm-official"):
        assert (
            sha(ROOT / f"build/{dialect}-parser")
            == provenance["binaries"][dialect]["sha256"]
        )
    for dialect, filename in (
        ("commonmark", "commonmark-0.31.2-spec.json"),
        ("gfm", "gfm-0.29-spec.html"),
    ):
        assert (
            sha(RESULTS / filename) == provenance["corpora"][dialect]["sha256"]
        )
    expected_classes = {
        "commonmark": {"A": 0, "U+FFFC": 1},
        "gfm": {"A": 0, "U+FFFC": 0},
        "gfm-official": {"A": 0, "U+FFFC": 0},
    }
    for dialect, expected in expected_classes.items():
        assert json.loads(invoke(dialect, "--classify")) == expected
    assert unicodedata.category(TOKENS["so"]) == "So"
    assert TOKENS["ascii"].isascii() and TOKENS["ascii"].isalnum()
    records = []
    for dialect in ("commonmark", "gfm", "gfm-official"):
        for token_kind in TOKENS:
            for fixture in cases(
                "gfm" if dialect == "gfm-official" else dialect, token_kind
            ):
                xml = invoke(dialect, "--xml", fixture["markdown"])
                actual = canonical(ET.fromstring(xml))
                records.append(
                    dict(
                        fixture,
                        candidate=dialect,
                        actual_ast=actual,
                        xml=xml,
                        html=invoke(dialect, "--html", fixture["markdown"]),
                        token_locations=locations(actual, fixture["token"]),
                        passed=actual == fixture["expected_ast"],
                    )
                )
    with (RESULTS / "ast-results.jsonl").open("w") as output:
        for record in records:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
    failures = [
        {
            "id": row["id"],
            "dialect": row["dialect"],
            "candidate": row["candidate"],
            "token_kind": row["token_kind"],
            "expected": row["expected_ast"],
            "actual": row["actual_ast"],
        }
        for row in records
        if not row["passed"]
    ]
    gfm = GFMExamples()
    gfm.feed((RESULTS / "gfm-0.29-spec.html").read_text())
    assert [row["example"] for row in gfm.examples] == list(range(1, 678)), (
        "Incomplete official GFM extraction"
    )
    cm_examples = json.loads(
        (RESULTS / "commonmark-0.31.2-spec.json").read_text()
    )
    assert [row["example"] for row in cm_examples] == list(range(1, 653)), (
        "Incomplete official CommonMark corpus"
    )
    (RESULTS / "gfm-official-examples.json").write_text(
        json.dumps(gfm.examples, indent=2, ensure_ascii=False) + "\n"
    )
    corpora = {
        "commonmark": corpus("commonmark", cm_examples),
        "gfm": corpus("gfm", gfm.examples),
        "gfm-official": corpus("gfm-official", gfm.examples),
    }
    actual_ids = {
        dialect: [row["example"] for row in data["mismatches"]]
        for dialect, data in corpora.items()
    }
    known_path = ROOT / "known-mismatches.json"
    known = (
        json.loads(known_path.read_text())
        if known_path.exists()
        else {"commonmark": [], "gfm": []}
    )
    summary = {
        "fixture_total": len(records),
        "fixture_passed": len(records) - len(failures),
        "fixture_failures": failures,
        "punctuation": expected_classes,
        "unicode_version": unicodedata.unidata_version,
        "official_corpora": corpora,
        "expected_corpus_mismatch_ids": known,
        "actual_corpus_mismatch_ids": actual_ids,
        "corpus_regression_passed": actual_ids == known,
        "input_sha256": {
            name: sha(ROOT / name)
            for name in (
                "harness.c",
                "fixtures.py",
                "run.py",
                "bootstrap.py",
                "test_lab.py",
                "known-mismatches.json",
            )
        },
    }
    (RESULTS / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n"
    )
    print(f"AST fixtures: {len(records) - len(failures)}/{len(records)} passed")
    for failure in failures:
        print(json.dumps(failure, ensure_ascii=False))
    for dialect, result in corpora.items():
        print(
            f"{dialect} official corpus: {result['exact_html_passed']}/{result['total']} exact HTML; mismatch IDs {actual_ids[dialect]}"
        )
    print(
        f"Corpus deviation regression: {'PASS' if actual_ids == known else 'FAIL'}"
    )
    return int(bool(failures) or actual_ids != known)


if __name__ == "__main__":
    record = {
        "argv": [sys.executable, *sys.argv],
        "cwd": str(Path.cwd()),
        "started_utc": datetime.datetime.now(datetime.UTC).isoformat(),
    }
    try:
        status = main()
        record["exit"] = status
        record["summary_sha256"] = sha(RESULTS / "summary.json")
    except Exception as error:
        record["exit"] = 1
        record["error"] = repr(error)
        raise
    finally:
        with (RESULTS / "test-commands.jsonl").open("a") as output:
            output.write(json.dumps(record) + "\n")
    sys.exit(status)
