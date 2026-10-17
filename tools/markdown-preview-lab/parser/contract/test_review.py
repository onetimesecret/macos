#!/usr/bin/env python3
"""Isolated review regressions; synthetic mutations never touch parser checkouts."""

import sys

sys.dont_write_bytecode = True
import datetime
import io
import json
import tempfile
import unittest
from functools import partial
from pathlib import Path
from unittest.mock import patch

import build
import run
from fixtures import n, text

OMITTED = [
    "src/entities.inc",
    "src/case_fold_switch.inc",
    "extensions/autolink.h",
    "extensions/ext_scanners.h",
    "extensions/strikethrough.h",
    "extensions/table.h",
    "extensions/tagfilter.h",
    "extensions/tasklist.h",
]
SCENARIOS = []


def record(name, **values):
    SCENARIOS.append(dict(name=name, **values))


def synthetic_source(directory):
    source = directory / "checkout"
    names = [*OMITTED, "COPYING"]
    for name in names:
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("synthetic original: " + name)
    return source, {name: build.sha(source / name) for name in names}


def test_mutation_rejected_before_parser(name, remove=False):
    with tempfile.TemporaryDirectory(dir=build.BUILD / "test-tmp") as temporary:
        directory = Path(temporary)
        source, manifest = synthetic_source(directory)
        target = source / name
        if remove:
            target.unlink()
        else:
            target.write_text(target.read_text() + "\nchanged")
        provenance = {
            "candidates": {
                "gfm": {
                    "source": "checkout",
                    "source_files_sha256": manifest,
                    "compile_input_sha256": {},
                }
            }
        }
        results = directory / "results"
        results.mkdir()
        (results / "provenance.json").write_text(json.dumps(provenance))
        with (
            patch.object(run, "RESULTS", results),
            patch.object(run, "REPO", directory),
            patch.object(run, "execute") as execute,
            patch.object(run.subprocess, "run") as subprocess_run,
        ):
            try:
                run.main()
            except RuntimeError as error:
                assert name in str(error), str(error)
            else:
                raise AssertionError("Modified source was accepted: " + name)
            execute.assert_not_called()
            subprocess_run.assert_not_called()
        record(
            ("missing:" if remove else "mutation:") + name,
            rejected=True,
            execute_calls=execute.call_count,
            subprocess_calls=subprocess_run.call_count,
            synthetic_only=True,
        )


def test_clean_synthetic_manifest():
    with tempfile.TemporaryDirectory(dir=build.BUILD / "test-tmp") as temporary:
        source, manifest = synthetic_source(Path(temporary))
        assert build.validate_source_manifest(source, manifest) == manifest
    record("clean-synthetic-manifest", files=9, passed=True)


def test_real_sources_still_match():
    provenance = json.loads(
        (build.ROOT / "results/provenance.json").read_text()
    )
    counts = {}
    for candidate, info in provenance["candidates"].items():
        actual = build.validate_source_manifest(
            build.REPO / info["source"], info["source_files_sha256"]
        )
        counts[candidate] = len(actual)
    assert sum(counts.values()) == 441
    record("real-sources-match", counts=counts, total=441)


def test_dependency_escaping():
    with tempfile.TemporaryDirectory(dir=build.BUILD / "test-tmp") as temporary:
        directory = Path(temporary)
        depfile = directory / "unit.d"
        depfile.write_text("out.o: src.c \\\n a\\ file\\ \\#$$.h\n")
        assert build.read_dependencies(depfile, directory) == sorted(
            [directory / "src.c", directory / "a file #$.h"]
        )
    record("dependency-escaping", passed=True)


def test_invalid_dependencies(contents):
    with tempfile.TemporaryDirectory(dir=build.BUILD / "test-tmp") as temporary:
        path = Path(temporary) / "unit.d"
        path.write_text(contents)
        try:
            build.read_dependencies(path)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Invalid dependency output was accepted")
    record("invalid-dependencies:" + repr(contents), rejected=True)


def test_real_compiler_dependencies():
    provenance = json.loads((build.RESULTS / "provenance.json").read_text())
    info = provenance["candidates"]["gfm"]
    for name in OMITTED:
        key = str(Path(info["source"]) / name)
        assert key in info["compile_input_sha256"], key
        assert any(
            key in unit["dependencies"] for unit in info["translation_units"]
        ), key
    units = sum(
        len(candidate["translation_units"])
        for candidate in provenance["candidates"].values()
    )
    assert units == 90
    record(
        "real-compiler-dependencies",
        translation_units=units,
        formerly_omitted_inputs=8,
    )


def span_case(markers="colspan"):
    dimensions = {
        "colspan": (2, 1),
        "rowspan": (1, 2),
        "colspan rowspan": (2, 2),
        "colspan_filler": (0, 1),
        "rowspan_filler": (1, 0),
    }
    col, row = dimensions[markers]
    children = [text("wide")] if col and row else []
    expected = n(
        "document",
        n(
            "table",
            n(
                "table_row",
                n("table_cell", *children, colspan=col, rowspan=row),
            ),
        ),
    )
    content = "<text>wide</text>" if children else ""
    source = (
        '<document><table><table_row><table_cell sourcepos="1:1-1:4" '
        + markers
        + ">"
        + content
        + "</table_cell></table_row></table></document>"
    )
    return source, expected


def test_known_span_repair(markers):
    source, expected = span_case(markers)
    original = source
    result = run.check_xml(source, expected)
    assert result["xml_check_passed"], result
    assert result["actual_xml_projection"] == run.xml_projection(expected)
    assert result["xml_span_repairs"][0]["attributes"] == markers.split()
    assert result["diagnostic_xml"] != source
    assert source == original
    record("known-span:" + markers, passed=True, original_unchanged=True)


BAD_XML = {
    "empty": "",
    "truncated": "<document><table><table_row><table_cell colspan><text>wide</text>",
    "unrelated-malformed": "<document><paragraph broken>wide</paragraph></document>",
    "wrong-element": "<document><table><table_row><paragraph colspan><text>wide</text></paragraph></table_row></table></document>",
    "unknown-valueless": "<document><table><table_row><table_cell colspan unknown><text>wide</text></table_cell></table_row></table></document>",
    "duplicate-marker": "<document><table><table_row><table_cell colspan colspan><text>wide</text></table_cell></table_row></table></document>",
    "unknown-combination": "<document><table><table_row><table_cell colspan rowspan_filler><text>wide</text></table_cell></table_row></table></document>",
    "missing-row": "<document><table><table_cell colspan><text>wide</text></table_cell></table></document>",
    "wrong-text": "<document><table><table_row><table_cell colspan><text>other</text></table_cell></table_row></table></document>",
    "unexpected-valid-xml": "<document><table><table_row><table_cell><text>wide</text></table_cell></table_row></table></document>",
}


def test_bad_xml_rejected(name):
    _, expected = span_case()
    result = run.check_xml(BAD_XML[name], expected)
    assert not result["xml_check_passed"], result
    record("bad-xml:" + name, rejected=True)


def test_preserves_quoted_and_literal_markers():
    source, expected = span_case()
    source = source.replace(
        'sourcepos="1:1-1:4"', 'sourcepos="colspan rowspan"'
    )
    source = source.replace("<text>wide</text>", "<text>colspan rowspan</text>")
    expected["children"][0]["children"][0]["children"][0]["children"][0][
        "literal"
    ] = "colspan rowspan"
    result = run.check_xml(source, expected)
    assert result["xml_check_passed"], result
    assert 'sourcepos="colspan rowspan"' in result["diagnostic_xml"]
    assert "<text>colspan rowspan</text>" in result["diagnostic_xml"]
    quoted = '<table_cell colspan="2" rowspan="3" />'
    assert run.repair_span_xml(quoted) == (quoted, [])
    record("quoted-and-literal-markers", passed=True)


def test_all_saved_xml_projections():
    path = build.ROOT / "results/fixtures.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    repaired = 0
    for row in rows:
        result = run.check_xml(row["actual_xml"], row["expected_ast"])
        assert result["xml_check_passed"], (row["mode"], row["id"], result)
        assert result["actual_xml_projection"] == run.xml_projection(
            row["expected_ast"]
        )
        repaired += bool(result["xml_span_repairs"])
    assert (len(rows), repaired) == (560, 30)
    record("saved-xml-projections", passed=560, repaired_diagnostic_copies=30)


def test_valid_xml_control():
    source = "<document><paragraph><text>note</text></paragraph></document>"
    expected = n("document", n("paragraph", text("note")))
    result = run.check_xml(source, expected)
    assert result["xml_check_passed"] and not result["xml_span_repairs"]
    assert result["diagnostic_xml"] is None
    record("valid-xml-control", passed=True)


def main():
    suite = unittest.TestSuite()
    tests = [
        ("real sources still match", test_real_sources_still_match),
        ("clean synthetic manifest", test_clean_synthetic_manifest),
        ("compiler dependency escaping", test_dependency_escaping),
        (
            "reject missing dependency rule",
            partial(test_invalid_dependencies, "not-a-rule"),
        ),
        (
            "reject empty dependency rule",
            partial(test_invalid_dependencies, "out.o:\n"),
        ),
        ("real compiler dependency coverage", test_real_compiler_dependencies),
        (
            "quoted/literal marker preservation",
            test_preserves_quoted_and_literal_markers,
        ),
        ("all saved XML projections", test_all_saved_xml_projections),
        ("well-formed XML control", test_valid_xml_control),
    ]
    tests += [
        (
            "reject mutation: " + name,
            partial(test_mutation_rejected_before_parser, name),
        )
        for name in [*OMITTED, "COPYING"]
    ]
    tests += [
        (
            "reject missing source",
            partial(test_mutation_rejected_before_parser, OMITTED[0], True),
        )
    ]
    tests += [
        (
            "repair only known markers: " + markers,
            partial(test_known_span_repair, markers),
        )
        for markers in (
            "colspan",
            "rowspan",
            "colspan rowspan",
            "colspan_filler",
            "rowspan_filler",
        )
    ]
    tests += [
        ("reject XML: " + name, partial(test_bad_xml_rejected, name))
        for name in BAD_XML
    ]
    for description, function in tests:

        def invoke_test(function=function):
            function()

        invoke_test.__name__ = description
        suite.addTest(
            unittest.FunctionTestCase(invoke_test, description=description)
        )
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    output = stream.getvalue()
    print(output, end="")
    report = dict(
        utc=datetime.datetime.now(datetime.UTC).isoformat(),
        argv=[sys.executable, *sys.argv],
        cwd=str(Path.cwd()),
        tests=result.testsRun,
        failures=len(result.failures),
        errors=len(result.errors),
        passed=result.wasSuccessful(),
        scenarios=SCENARIOS,
        output=output,
        input_sha256={
            name: build.sha(build.ROOT / name)
            for name in ("build.py", "run.py", "test_review.py")
        },
    )
    (build.RESULTS / "regression-tests.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
