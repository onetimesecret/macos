#!/usr/bin/env python3
"""Reproduce threshold selection from committed tuning rankings."""

from __future__ import annotations

import argparse
import itertools
import json
from pathlib import Path


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_cases(path: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line
    ]


def accepted_slug(
    case: dict, evidence: int, score: float, margin: float, maximum: int
):
    if not case["eligible"] or case["input_bytes"] > maximum:
        return None
    if case["non_whitespace_bytes"] < evidence or len(case["ranked"]) < 2:
        return None
    top, second = case["ranked"][:2]
    if top["score"] < score or top["score"] < second["score"] + margin:
        return None
    return top["slug"]


def ratio(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def evaluate(
    cases: list[dict], evidence: int, score: float, margin: float, maximum: int
) -> dict:
    paste_useful = sum(
        case["surface"] == "paste" and case["useful_code"] for case in cases
    )
    conversions = 0
    useful_conversions = 0
    dedicated_total = 0
    dedicated_conversions = 0
    for case in cases:
        slug = accepted_slug(case, evidence, score, margin, maximum)
        automatic = case["surface"] == "paste" and slug not in (
            None,
            "markdown",
        )
        conversions += automatic
        useful_conversions += automatic and case["useful_code"]
        dedicated = (
            case["surface"] == "paste"
            and not case["useful_code"]
            and case["kind"] in ("prose", "list", "url")
        )
        dedicated_total += dedicated
        dedicated_conversions += dedicated and automatic
    return {
        "minimum_non_whitespace_bytes": evidence,
        "minimum_top_score": score,
        "minimum_top_two_margin": margin,
        "maximum_input_bytes": maximum,
        "automatic_paste_conversions": conversions,
        "automatic_paste_precision": ratio(useful_conversions, conversions),
        "automatic_paste_useful_code_coverage": ratio(
            useful_conversions, paste_useful
        ),
        "dedicated_paste_negative_conversions": dedicated_conversions,
        "dedicated_paste_negative_cases": dedicated_total,
    }


def passes(row: dict, selection: dict) -> bool:
    precision = row["automatic_paste_precision"]
    return (
        precision is not None
        and precision >= selection["minimum_automatic_paste_precision"]
        and row["dedicated_paste_negative_conversions"]
        <= selection["maximum_dedicated_paste_negative_conversions"]
        and (
            not selection["require_automatic_paste_conversion"]
            or row["automatic_paste_conversions"] > 0
        )
    )


def selection_key(row: dict):
    return (
        row["automatic_paste_useful_code_coverage"],
        row["automatic_paste_precision"],
        -row["minimum_non_whitespace_bytes"],
        -row["minimum_top_score"],
        -row["minimum_top_two_margin"],
    )


def markdown_report(report: dict) -> str:
    selected = report["selected"]
    lines = [
        "# Tuning threshold selection",
        "",
        "This table is generated from committed tuning-only raw rankings. It reproduces the selection calculation; it does not establish the chronology of the original holdout run.",
        "",
        f"Candidates evaluated: **{report['candidate_count']}**; qualifying: **{report['qualifying_candidate_count']}**.",
        "",
        "| Evidence bytes | Top score | Margin | Conversions | Precision | Useful-code coverage | Dedicated negative conversions | Qualifies |",
        "|---:|---:|---:|---:|---:|---:|---:|:---:|",
    ]
    selection = report["grid"]["selection"]
    for row in report["candidates"]:
        precision = row["automatic_paste_precision"]
        coverage = row["automatic_paste_useful_code_coverage"]
        lines.append(
            "| {minimum_non_whitespace_bytes} | {minimum_top_score:.2f} | {minimum_top_two_margin:.2f} | {automatic_paste_conversions} | {precision} | {coverage} | {dedicated_paste_negative_conversions}/{dedicated_paste_negative_cases} | {qualifies} |".format(
                **row,
                precision="n/a" if precision is None else f"{precision:.2%}",
                coverage="n/a" if coverage is None else f"{coverage:.2%}",
                qualifies="yes" if passes(row, selection) else "no",
            )
        )
    lines.extend(
        [
            "",
            "Selected: `{minimum_non_whitespace_bytes} / {minimum_top_score:.2f} / {minimum_top_two_margin:.2f}` with {automatic_paste_useful_code_coverage:.2%} useful-code coverage.".format(
                **selected
            ),
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--grid", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--markdown-output", type=Path)
    parser.add_argument("--expect-candidate", type=Path)
    args = parser.parse_args()

    cases = load_cases(args.cases)
    if not cases or {case["split"] for case in cases} != {"tune"}:
        raise SystemExit("selection input must contain only tuning cases")
    grid = load_json(args.grid)
    if (
        grid["selection"]["objective"]
        != "maximize_automatic_paste_useful_code_coverage"
    ):
        raise SystemExit("unsupported selection objective")

    rows = [
        evaluate(cases, evidence, score, margin, grid["maximum_input_bytes"])
        for evidence, score, margin in itertools.product(
            grid["minimum_non_whitespace_bytes"],
            grid["minimum_top_score"],
            grid["minimum_top_two_margin"],
        )
    ]
    qualifying = [row for row in rows if passes(row, grid["selection"])]
    if not qualifying:
        raise SystemExit(
            "no threshold candidate meets the tuning selection constraints"
        )
    selected = max(qualifying, key=selection_key)
    report = {
        "schema_version": 1,
        "input_cases": str(args.cases),
        "grid": grid,
        "candidate_count": len(rows),
        "qualifying_candidate_count": len(qualifying),
        "selected": selected,
        "candidates": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    if args.markdown_output:
        args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_output.write_text(
            markdown_report(report), encoding="utf-8"
        )

    if args.expect_candidate:
        expected = load_json(args.expect_candidate)
        selected_thresholds = {key: selected[key] for key in expected}
        if selected_thresholds != expected:
            raise SystemExit(
                f"selected thresholds {selected_thresholds!r} do not match {expected!r}"
            )
    print(json.dumps(selected, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
