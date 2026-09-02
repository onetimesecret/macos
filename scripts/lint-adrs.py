#!/usr/bin/env python3
"""Check ADRs against the conventions in docs/adr/README.md.

Structure only: metadata that must be present and well formed, the four
sections every record carries, and links that must resolve. Nothing here
judges content, length, or style.

Usage: scripts/lint-adrs.py [docs/adr]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DOC_STATUS = {"draft", "needs-review", "reviewed", "stale"}
ADR_STATUS = {"proposed", "accepted", "rejected", "superseded"}
REQUIRED_SECTIONS = ("Context", "Decision", "Consequences", "Eject triggers")

ADR_FILE = re.compile(r"^(\d{4})-[a-z0-9-]+\.md$")
TITLE = re.compile(r"^# ADR-(\d{4}): \S")
# A canonical metadata bullet: "- **Field:** value", value optionally on
# the following lines.
FIELD = re.compile(r"^- \*\*([^*]+):\*\*[ \t]*(.*)$")
LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
# Inline code spans; a link written inside one is an example, not a link.
CODE_SPAN = re.compile(r"`[^`]*`")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DOC_STATUS_LINE = re.compile(r"^documentation_status:[ \t]*([a-z-]+)[ \t]*(?:#.*)?$")
# The frontmatter key restated as a visible field, which would let the two
# copies drift.
VISIBLE_DOC_STATUS = re.compile(r"documentation[_ -]status", re.IGNORECASE)


def split_frontmatter(lines: list[str]) -> tuple[list[str], int]:
    """Return the frontmatter lines and the index of the body's first line."""
    if not lines or lines[0].rstrip() != "---":
        return [], 0
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            return lines[1:i], i + 1
    return [], 0


def check(path: Path, adr_dir: Path) -> list[str]:
    problems: list[str] = []

    def bad(line_no: int | None, msg: str) -> None:
        where = f"{path.name}:{line_no}" if line_no else path.name
        problems.append(f"{where}: {msg}")

    name_match = ADR_FILE.match(path.name)
    if not name_match:
        bad(None, "filename is not NNNN-lower-kebab-slug.md")
        return problems
    number = name_match.group(1)

    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    front, body_start = split_frontmatter(lines)

    if not front:
        bad(1, "missing --- frontmatter block")
    else:
        found = [
            (i, m.group(1))
            for i, raw in enumerate(front, start=2)
            for m in [DOC_STATUS_LINE.match(raw.strip())]
            if m
        ]
        raw_keys = [
            i for i, raw in enumerate(front, start=2)
            if raw.strip().startswith("documentation_status")
        ]
        if not raw_keys:
            bad(1, "frontmatter has no documentation_status")
        elif len(raw_keys) > 1:
            bad(raw_keys[1], "frontmatter has more than one documentation_status")
        elif not found:
            bad(raw_keys[0], "documentation_status is not a bare value plus optional # comment")
        elif found[0][1] not in DOC_STATUS:
            bad(found[0][0], f"documentation_status '{found[0][1]}' is not one of {sorted(DOC_STATUS)}")

    body = lines[body_start:]

    titles = [i for i, raw in enumerate(body, start=body_start + 1) if raw.startswith("# ")]
    if len(titles) != 1:
        bad(None, f"expected exactly one level-one heading, found {len(titles)}")
    else:
        raw = lines[titles[0] - 1]
        m = TITLE.match(raw)
        if not m:
            bad(titles[0], "title is not '# ADR-NNNN: Title'")
        elif m.group(1) != number:
            bad(titles[0], f"title says ADR-{m.group(1)}, filename says {number}")

    # Canonical metadata bullets, which live between the title and the first
    # section heading.
    fields: dict[str, tuple[int, str]] = {}
    duplicates: list[tuple[int, str]] = []
    for i, raw in enumerate(body, start=body_start + 1):
        if raw.startswith("## "):
            break
        m = FIELD.match(raw)
        if not m:
            continue
        key = m.group(1).strip()
        if key in fields:
            duplicates.append((i, key))
        else:
            fields[key] = (i, m.group(2).strip())

    for line_no, key in duplicates:
        bad(line_no, f"metadata field '{key}' appears more than once")

    if "Status" not in fields:
        bad(None, "no canonical '- **Status:**' metadata field")
    else:
        line_no, value = fields["Status"]
        if value not in ADR_STATUS:
            bad(line_no, f"Status '{value}' is not one of {sorted(ADR_STATUS)}")
        elif value == "superseded":
            if "Superseded by" not in fields:
                bad(line_no, "Status is superseded but no 'Superseded by' field names a successor")
            else:
                sb_line, sb_value = fields["Superseded by"]
                tail = "\n".join(lines[sb_line - 1 : sb_line + 6])
                if not LINK.search(tail):
                    bad(sb_line, "'Superseded by' does not link the successor ADR")

    if "Date" not in fields:
        bad(None, "no canonical '- **Date:**' metadata field")
    elif not ISO_DATE.match(fields["Date"][1]):
        bad(fields["Date"][0], f"Date '{fields['Date'][1]}' is not YYYY-MM-DD")

    for key, (line_no, _) in fields.items():
        if VISIBLE_DOC_STATUS.search(key):
            bad(line_no, "documentation_status is restated as a visible metadata field")

    headings = {raw[3:].strip() for raw in body if raw.startswith("## ")}
    for section in REQUIRED_SECTIONS:
        if section not in headings:
            bad(None, f"missing required '## {section}' section")

    in_fence = False
    for i, raw in enumerate(lines, start=1):
        if raw.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for target in LINK.findall(CODE_SPAN.sub("", raw)):
            target = target.strip().split(" ")[0]
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            rel, _, _ = target.partition("#")
            if not rel:
                continue
            if not (adr_dir / rel).exists():
                bad(i, f"link target does not resolve: {target}")

    return problems


def main(argv: list[str]) -> int:
    adr_dir = Path(argv[1] if len(argv) > 1 else "docs/adr")
    if not adr_dir.is_dir():
        print(f"not a directory: {adr_dir}", file=sys.stderr)
        return 2

    files = sorted(p for p in adr_dir.glob("*.md") if p.name[0].isdigit())
    if not files:
        print(f"no ADRs found in {adr_dir}", file=sys.stderr)
        return 2

    numbers: dict[str, Path] = {}
    problems: list[str] = []
    for path in files:
        m = ADR_FILE.match(path.name)
        if m:
            if m.group(1) in numbers:
                problems.append(
                    f"{path.name}: reuses the number of {numbers[m.group(1)].name}"
                )
            else:
                numbers[m.group(1)] = path
        problems.extend(check(path, adr_dir))

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problem(s) in {len(files)} ADR(s)", file=sys.stderr)
        return 1
    print(f"{len(files)} ADRs OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
