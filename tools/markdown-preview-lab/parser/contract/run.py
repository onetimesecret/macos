#!/usr/bin/env python3
"""Run offline C contract fixtures without executing any previous lab script."""

import sys

sys.dont_write_bytecode = True
import datetime
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

from build import (
    BUILD,
    LAB,
    REPO,
    RESULTS,
    ROOT,
    WRAPPER,
    dependency_name,
    protected_files,
    read_dependencies,
    sha,
    validate_source_manifest,
)
from fixtures import cases
from profiles import MODES


def execute(argv, source):
    result = subprocess.run(
        [str(arg) for arg in argv],
        input=source,
        text=True,
        capture_output=True,
        timeout=10,
    )
    if result.returncode:
        raise RuntimeError(f"{argv}: exit {result.returncode}: {result.stderr}")
    return result.stdout


def invoke(mode, output, source=""):
    return execute(
        [BUILD / f"{mode['candidate']}-contract", mode["profile"], output],
        source,
    )


def normalize(node):
    result = {key: value for key, value in node.items() if key != "children"}
    children = []
    for child in node.get("children", []):
        child = normalize(child)
        if child == {"type": "text", "literal": ""}:
            continue
        if children and children[-1]["type"] == child["type"] == "text":
            children[-1]["literal"] += child["literal"]
        else:
            children.append(child)
    if children:
        result["children"] = children
    return result


def xml_projection(node):
    value = {
        key: val
        for key, val in node.items()
        if key not in ("children", "properties")
    }
    if node["type"] in ("link", "image"):
        value["properties"] = node["properties"]
    if node.get("children"):
        value["children"] = [
            xml_projection(child) for child in node["children"]
        ]
    return normalize(value)


def from_xml(element):
    kind = element.tag.rsplit("}", 1)[-1]
    node = {"type": kind}
    if kind in ("text", "code", "code_block", "html_block", "html_inline"):
        node["literal"] = element.text or ""
    if kind in ("link", "image"):
        node["properties"] = {
            "destination": element.get("destination", ""),
            "title": element.get("title", ""),
        }
    if list(element):
        node["children"] = [from_xml(child) for child in element]
    return normalize(node)


def expected_xml(node):
    element = ET.Element(
        node["type"],
        {key: str(value) for key, value in node.get("properties", {}).items()},
    )
    if "literal" in node:
        element.text = node["literal"]
    for child in node.get("children", []):
        element.append(expected_xml(child))
    return element


def expected_invalid_xml(node, header=False):
    header = header or node["type"] == "table_header"
    props = node.get("properties", {})
    if (
        node["type"] == "table_cell"
        and not header
        and (props.get("colspan", 1) != 1 or props.get("rowspan", 1) != 1)
    ):
        return True
    return any(
        expected_invalid_xml(child, header)
        for child in node.get("children", [])
    )


CELL_TAG = re.compile(r"""<table_cell(?=[\s/>])(?:[^<>"']|"[^"]*"|'[^']*')*>""")
XML_ATTRIBUTE = re.compile(
    r"""\s+(?P<name>[A-Za-z_:][\w.:-]*)(?P<value>\s*=\s*(?:"[^"]*"|'[^']*'))?"""
)
SPAN_MARKER_SETS = {
    ("colspan",),
    ("rowspan",),
    ("colspan", "rowspan"),
    ("colspan_filler",),
    ("rowspan_filler",),
}
SPAN_MARKERS = {name for names in SPAN_MARKER_SETS for name in names}


def repair_span_xml(source):
    repairs = []

    def repair(match):
        tag = match.group(0)
        close = "/>" if tag.endswith("/>") else ">"
        body = tag[len("<table_cell") : -len(close)]
        pieces, markers, seen = [], [], set()
        offset = 0
        while offset < len(body):
            if not body[offset:].strip():
                pieces.append(body[offset:])
                break
            attribute = XML_ATTRIBUTE.match(body, offset)
            if attribute is None:
                raise ValueError("Malformed table_cell attribute syntax")
            name = attribute["name"]
            if name in seen:
                raise ValueError("Duplicate table_cell attribute: " + name)
            seen.add(name)
            if attribute["value"] is None:
                if name not in SPAN_MARKERS:
                    raise ValueError(
                        "Unknown valueless table_cell attribute: " + name
                    )
                markers.append(name)
            else:
                pieces.append(attribute.group(0))
            offset = attribute.end()
        if markers:
            if tuple(markers) not in SPAN_MARKER_SETS:
                raise ValueError("Unexpected span marker combination")
            repairs.append(dict(offset=match.start(), attributes=markers))
        return "<table_cell" + "".join(pieces) + close

    return CELL_TAG.sub(repair, source), repairs


def check_xml(source, expected_ast):
    invalid_expected = expected_invalid_xml(expected_ast)
    expected_projection = xml_projection(expected_ast)
    result = dict(
        expected_upstream_xml_well_formed=not invalid_expected,
        actual_xml_error=None,
        expected_xml_projection=expected_projection,
        actual_xml_projection=None,
        diagnostic_xml=None,
        xml_span_repairs=[],
        xml_diagnostic_error=None,
        xml_check_passed=False,
    )
    try:
        projection = from_xml(ET.fromstring(source))
    except ET.ParseError as error:
        result["actual_xml_error"] = str(error)
        if not invalid_expected:
            return result
        try:
            diagnostic, repairs = repair_span_xml(source)
            if not repairs:
                raise ValueError("No known valueless span attributes to repair")
            result["diagnostic_xml"] = diagnostic
            result["xml_span_repairs"] = repairs
            projection = from_xml(ET.fromstring(diagnostic))
        except (ET.ParseError, ValueError) as repair_error:
            result["xml_diagnostic_error"] = str(repair_error)
            return result
    else:
        if invalid_expected:
            result["actual_xml_projection"] = projection
            result["xml_diagnostic_error"] = (
                "Expected upstream span serialization defect was absent"
            )
            return result
    result["actual_xml_projection"] = projection
    result["xml_check_passed"] = projection == expected_projection
    if not result["xml_check_passed"]:
        result["xml_diagnostic_error"] = (
            "XML projection differs from the expected tree"
        )
    return result


def write_jsonl(path, rows):
    with path.open("w") as output:
        for row in rows:
            output.write(json.dumps(row, ensure_ascii=False) + "\n")


def preflight(provenance):
    for info in provenance["candidates"].values():
        validate_source_manifest(
            REPO / info["source"], info["source_files_sha256"]
        )
    for name, expected in provenance["contract_inputs_sha256"].items():
        if sha(ROOT / name) != expected:
            raise RuntimeError("Rebuild changed contract input: " + name)
    for name, info in provenance["wrapper"]["files"].items():
        if sha(WRAPPER / name) != info["sha256"]:
            raise RuntimeError("Inspected wrapper source changed: " + name)
    for candidate, info in provenance["candidates"].items():
        if sha(BUILD / f"{candidate}-contract") != info["binary_sha256"]:
            raise RuntimeError("Contract executable changed: " + candidate)
        dependencies = set()
        for unit in info["translation_units"]:
            depfile = REPO / unit["dependency_file"]
            if sha(depfile) != unit["dependency_file_sha256"]:
                raise RuntimeError(
                    "Compiler dependency file changed: " + str(depfile)
                )
            names = {
                dependency_name(path, REPO)
                for path in read_dependencies(depfile, REPO)
            }
            if names != set(unit["dependencies"]):
                raise RuntimeError(
                    "Compiler dependency list changed: " + str(depfile)
                )
            dependencies.update(names)
        if dependencies != set(info["compile_input_sha256"]):
            raise RuntimeError(
                "Compilation input manifest differs from compiler dependencies: "
                + candidate
            )
        for name, digest in info["compile_input_sha256"].items():
            if sha(REPO / name) != digest:
                raise RuntimeError("Compilation input changed: " + name)
        if (
            sha(LAB / f"build/{candidate}-parser")
            != info["previous_binary_sha256"]
        ):
            raise RuntimeError("Original executable changed: " + candidate)
        if "minos 13.0" not in info["mach_o_load_commands"]:
            raise RuntimeError(
                "Expected macOS 13.0 binary target: " + candidate
            )


def main():
    provenance = json.loads((RESULTS / "provenance.json").read_text())
    preflight(provenance)
    prior = json.loads((LAB / "results/provenance.json").read_text())
    for family, name in (
        ("commonmark", "commonmark-0.31.2-spec.json"),
        ("gfm", "gfm-0.29-spec.html"),
    ):
        if sha(LAB / "results" / name) != prior["corpora"][family]["sha256"]:
            raise RuntimeError("Saved official corpus changed: " + family)
    baseline = json.loads((RESULTS / "start-state.json").read_text())[
        "protected_sha256"
    ]
    before = protected_files()
    before_changed = [
        name
        for name in set(baseline) | set(before)
        if baseline.get(name) != before.get(name)
    ]
    blocking_before = [
        name for name in before_changed if not name.startswith("docs/")
    ]
    if blocking_before:
        raise RuntimeError(
            "Protected parser/configuration inputs changed: "
            + repr(blocking_before)
        )
    records, official, metadata = [], [], []
    for name, mode in MODES.items():
        meta = json.loads(invoke(mode, "--meta"))
        meta_ok = (
            meta == provenance["candidates"][mode["candidate"]]["modes"][name]
        )
        metadata.append(
            dict(
                mode=name,
                expected=provenance["candidates"][mode["candidate"]]["modes"][
                    name
                ],
                actual=meta,
                passed=meta_ok,
            )
        )
        matrix = cases(mode)
        if len(matrix) != 40 or len({row["id"] for row in matrix}) != 40:
            raise RuntimeError("Incomplete or duplicate fixture IDs in " + name)
        for fixture in matrix:
            source = fixture["markdown"]
            actual_ast = normalize(json.loads(invoke(mode, "--json", source)))
            actual_html = invoke(mode, "--html", source)
            actual_xml = invoke(mode, "--xml", source)
            expected_ast = normalize(fixture["expected_ast"])
            xml_result = check_xml(actual_xml, expected_ast)
            row = dict(
                fixture,
                mode=name,
                candidate=mode["candidate"],
                actual_ast=actual_ast,
                actual_html=actual_html,
                actual_xml=actual_xml,
                expected_xml=ET.tostring(
                    expected_xml(expected_ast), encoding="unicode"
                ),
                **xml_result,
                ast_passed=actual_ast == expected_ast,
                html_passed=actual_html == fixture["expected_html"],
            )
            row["passed"] = (
                row["ast_passed"]
                and row["html_passed"]
                and row["xml_check_passed"]
            )
            records.append(row)
            if fixture["official_oracle"]:
                oracle = fixture["official_oracle"]
                expected_equal = (
                    fixture["expected_html"] == oracle["expected_html"]
                )
                actual_equal = actual_html == oracle["expected_html"]
                official.append(
                    dict(
                        mode=name,
                        id=fixture["id"],
                        **oracle,
                        mode_expected_html=fixture["expected_html"],
                        actual_html=actual_html,
                        expected_equal=expected_equal,
                        actual_equal=actual_equal,
                        regression_passed=actual_equal == expected_equal,
                    )
                )
    previous = []
    for name in ("cm-core", "legacy-gfm", "swift-gfm"):
        mode = MODES[name]
        for fixture in cases(mode):
            for kind in ("html", "xml"):
                old = execute(
                    [LAB / f"build/{mode['candidate']}-parser", "--" + kind],
                    fixture["markdown"],
                )
                current = invoke(mode, "--" + kind, fixture["markdown"])
                previous.append(
                    dict(
                        mode=name,
                        id=fixture["id"],
                        format=kind,
                        previous=old,
                        actual=current,
                        equal=old == current,
                    )
                )
    by_mode_id = {(row["mode"], row["id"]): row for row in records}
    pairs = []
    for a, b, allowed in (
        ("swift-preview", "swift-preview-no-sourcepos", set()),
        (
            "swift-preview",
            "swift-preview-spans-off",
            {row["id"] for row in records if row["id"].startswith("table-")},
        ),
        ("swift-preview", "swift-default", {"smart-option-control"}),
    ):
        for fixture in cases(MODES[a]):
            identifier = fixture["id"]
            left, right = (
                by_mode_id[(a, identifier)],
                by_mode_id[(b, identifier)],
            )
            same = (
                left["actual_ast"] == right["actual_ast"]
                and left["actual_html"] == right["actual_html"]
            )
            expected_same = (
                left["expected_ast"] == right["expected_ast"]
                and left["expected_html"] == right["expected_html"]
            )
            pairs.append(
                dict(
                    a=a,
                    b=b,
                    id=identifier,
                    actual_equal=same,
                    expected_equal=expected_same,
                    passed=same == expected_same
                    and (same or identifier in allowed),
                )
            )
    preflight(provenance)
    write_jsonl(RESULTS / "fixtures.jsonl", records)
    write_jsonl(RESULTS / "official-comparisons.jsonl", official)
    write_jsonl(RESULTS / "previous-binary-comparisons.jsonl", previous)
    write_jsonl(RESULTS / "mode-pairs.jsonl", pairs)
    (RESULTS / "mode-metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n"
    )
    protected_after = protected_files()
    changed = sorted(
        name
        for name in set(baseline) | set(protected_after)
        if baseline.get(name) != protected_after.get(name)
    )
    blocking_changes = [
        name for name in changed if not name.startswith("docs/")
    ]
    external_document_changes = [
        dict(
            path=name,
            before_sha256=baseline.get(name),
            after_sha256=protected_after.get(name),
        )
        for name in changed
        if name.startswith("docs/")
    ]
    failures = [
        dict(
            mode=row["mode"],
            id=row["id"],
            ast=row["ast_passed"],
            html=row["html_passed"],
            xml=row["xml_check_passed"],
        )
        for row in records
        if not row["passed"]
    ]
    per_mode = {
        name: dict(
            fixtures=sum(row["mode"] == name for row in records),
            passed=sum(
                row["mode"] == name and row["passed"] for row in records
            ),
            official_mismatch_ids=[
                row["id"]
                for row in official
                if row["mode"] == name and not row["actual_equal"]
            ],
        )
        for name in MODES
    }
    summary = dict(
        utc=datetime.datetime.now(datetime.UTC).isoformat(),
        build_root_revision=provenance["repository_revision"],
        tested_root_revision=execute(
            ["git", "--no-pager", "rev-parse", "HEAD"], ""
        ).strip(),
        fixture_total=len(records),
        fixture_passed=sum(row["passed"] for row in records),
        fixture_failures=failures,
        ast_assertions=sum(row["ast_passed"] for row in records),
        html_assertions=sum(row["html_passed"] for row in records),
        xml_assertions=sum(row["xml_check_passed"] for row in records),
        xml_projection_assertions=sum(
            row["actual_xml_projection"] == row["expected_xml_projection"]
            for row in records
        ),
        xml_diagnostic_repair_count=sum(
            bool(row["xml_span_repairs"]) for row in records
        ),
        complete_source_manifest_files={
            candidate: len(info["source_files_sha256"])
            for candidate, info in provenance["candidates"].items()
        },
        expected_invalid_xml_count=sum(
            not row["expected_upstream_xml_well_formed"] for row in records
        ),
        actual_invalid_xml_count=sum(
            bool(row["actual_xml_error"]) for row in records
        ),
        mode_metadata_total=len(metadata),
        mode_metadata_passed=sum(row["passed"] for row in metadata),
        previous_binary_comparisons=len(previous),
        previous_binary_equal=sum(row["equal"] for row in previous),
        mode_pair_comparisons=len(pairs),
        mode_pair_passed=sum(row["passed"] for row in pairs),
        official_comparisons=len(official),
        official_equal=sum(row["actual_equal"] for row in official),
        official_regression_passed=sum(
            row["regression_passed"] for row in official
        ),
        official_mismatches=[
            row for row in official if not row["actual_equal"]
        ],
        official_mismatch_counts_by_fixture={
            identifier: sum(
                row["id"] == identifier and not row["actual_equal"]
                for row in official
            )
            for identifier in sorted({row["id"] for row in official})
        },
        invalid_xml_counts_by_fixture={
            identifier: sum(
                row["id"] == identifier and bool(row["actual_xml_error"])
                for row in records
            )
            for identifier in sorted(
                {row["id"] for row in records if row["actual_xml_error"]}
            )
        },
        per_mode=per_mode,
        protected_files_checked=len(baseline),
        changed_protected_files=changed,
        blocking_input_changes=blocking_changes,
        concurrent_document_changes=external_document_changes,
        input_sha256={
            name: sha(ROOT / name)
            for name in (
                "build.py",
                "harness.c",
                "profiles.py",
                "fixtures.py",
                "run.py",
            )
        },
        provenance_sha256=sha(RESULTS / "provenance.json"),
        oracle_notice="../CORPUS-NOTICE.md; official-example-containing adaptations are CC-BY-SA 4.0",
    )
    passed = (
        not failures
        and not blocking_changes
        and all(row["passed"] for row in metadata + pairs)
        and all(row["equal"] for row in previous)
        and all(row["regression_passed"] for row in official)
    )
    summary["passed"] = passed
    (RESULTS / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n"
    )
    print(
        f"Fixture rows: {summary['fixture_passed']}/{len(records)}; AST/HTML/XML checks: {summary['ast_assertions']}/{summary['html_assertions']}/{summary['xml_assertions']}"
    )
    print(
        f"Raw XML invalid as expected: {summary['actual_invalid_xml_count']}/{summary['expected_invalid_xml_count']}"
    )
    print(
        f"Mode metadata: {summary['mode_metadata_passed']}/{len(metadata)}; mode pairs: {summary['mode_pair_passed']}/{len(pairs)}"
    )
    print(
        f"Previous-binary exact comparisons: {summary['previous_binary_equal']}/{len(previous)}"
    )
    print(
        f"Selected official HTML: {summary['official_equal']}/{len(official)}; expected deviations: {len(official) - summary['official_equal']}; regression checks: {summary['official_regression_passed']}/{len(official)}"
    )
    print(
        f"Parser/configuration input changes: {blocking_changes}; concurrent document changes: {[row['path'] for row in external_document_changes]} ({len(baseline)} audited hashes); result: {'PASS' if passed else 'FAIL'}"
    )
    for failure in failures:
        print(json.dumps(failure))
    return 0 if passed else 1


if __name__ == "__main__":
    event = dict(
        argv=[sys.executable, *sys.argv],
        cwd=str(Path.cwd()),
        started_utc=datetime.datetime.now(datetime.UTC).isoformat(),
    )
    try:
        status = main()
        event["exit"] = status
        event["summary_sha256"] = sha(RESULTS / "summary.json")
    except Exception as error:
        event["exit"] = 1
        event["error"] = repr(error)
        raise
    finally:
        with (RESULTS / "commands.jsonl").open("a") as output:
            output.write(json.dumps(event) + "\n")
    sys.exit(status)
