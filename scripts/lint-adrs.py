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

REPO_ROOT = Path(__file__).resolve().parent.parent

DOC_STATUS = {"draft", "needs-review", "reviewed", "stale"}
ADR_STATUS = {"proposed", "accepted", "rejected", "superseded"}
REQUIRED_SECTIONS = ("Context", "Decision", "Consequences", "Eject triggers")
RELATION_FIELDS = {
    "Depends on",
    "Superseded by",
    "Superseded in part by",
    "Supersedes",
    "Supersedes in part",
}
# Every metadata key the README makes canonical. Lifecycle events belong in
# the dated '## Decision history' section, not here, so the list stays short
# on purpose. documentation_status is frontmatter and is deliberately absent.
ALLOWED_FIELDS = {"Status", "Date", "Ratified"} | RELATION_FIELDS
# Relationships the README requires a back reference for. 'Depends on' is
# navigational only, so it carries no reciprocal obligation.
RECIPROCAL_FIELDS = {
    "Superseded by": "Supersedes",
    "Supersedes": "Superseded by",
    "Superseded in part by": "Supersedes in part",
    "Supersedes in part": "Superseded in part by",
}

ADR_FILE = re.compile(r"^(\d{4})-(?:[a-z0-9]+-)*[a-z0-9]+\.md$")
TITLE = re.compile(r"^# ADR-(\d{4}): \S")
# An optional first line naming the file's own path, as in
# "# docs/adr/0035-slug.md". It is a header comment above the frontmatter,
# not the record's title.
FILE_HEADER = re.compile(r"^#[ \t]+(\S+\.md)[ \t]*$")
# A canonical metadata bullet: "- **Field:** value", value optionally on
# the following lines.
FIELD = re.compile(r"^- \*\*([^*]+):\*\*[ \t]*(.*)$")
LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
# Inline code spans of any backtick run length; a link written inside one is
# an example, not a link.
CODE_SPAN = re.compile(r"(`+).*?\1")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DOC_STATUS_LINE = re.compile(
    r"^documentation_status:[ \t]*([a-z-]+)[ \t]*(?:#.*)?$"
)
# The frontmatter key restated as a visible field, which would let the two
# copies drift.
VISIBLE_DOC_STATUS = re.compile(r"documentation[_ -]status", re.IGNORECASE)
# A Markdown inline link, reduced to its text when a heading is slugged.
INLINE_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
SLUG_STRIP = re.compile(r"[^\w\- ]", re.UNICODE)


def split_frontmatter(lines: list[str]) -> tuple[list[str], int, str | None]:
    """Split a file into frontmatter and body.

    Returns the frontmatter lines, the index of the body's first line, and
    an error tag: "missing" when there is no opening `---`, "unterminated"
    when the opening `---` has no closing partner, None otherwise. The two
    failures are distinct: an unterminated block has no body at all, so
    scanning one as body would count a `# ` line inside the frontmatter as
    the record's title.
    """
    if not lines or lines[0].rstrip() != "---":
        return [], 0, "missing"
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            return lines[1:i], i + 1, None
    return lines[1:], len(lines), "unterminated"


def outside_fences(lines: list[str]) -> list[tuple[int, str]]:
    """Return numbered Markdown lines that are not inside code fences."""
    visible: list[tuple[int, str]] = []
    fence: str | None = None
    for line_no, raw in enumerate(lines, start=1):
        stripped = raw.lstrip()
        marker = next(
            (
                candidate
                for candidate in ("```", "~~~")
                if stripped.startswith(candidate)
            ),
            None,
        )
        if marker:
            if fence is None:
                fence = marker
            elif marker == fence:
                fence = None
            continue
        if fence is None:
            visible.append((line_no, raw))
    return visible


def field_block(lines: list[str], line_no: int) -> str:
    """Return one metadata bullet and its indented continuation lines."""
    block = [lines[line_no - 1]]
    for raw in lines[line_no:]:
        if not raw.strip() or raw.startswith(("- **", "## ")):
            break
        if not raw.startswith(("  ", "\t")):
            break
        block.append(raw)
    return "\n".join(block)


def clean_link_target(target: str) -> str:
    """Remove an optional Markdown link title from a link target."""
    return target.strip().split(" ", 1)[0]


def slugify(heading: str) -> str:
    """Slug a heading the way GitHub anchors do."""
    text = INLINE_LINK.sub(r"\1", heading).strip()
    text = SLUG_STRIP.sub("", text.lower())
    return text.replace(" ", "-")


_ANCHOR_CACHE: dict[Path, set[str] | None] = {}


def anchors(path: Path) -> set[str] | None:
    """Return the anchors of a Markdown file, or None if it cannot be read.

    Duplicate headings take GitHub's `-1`, `-2`, ... suffixes.
    """
    resolved = path.resolve()
    if resolved in _ANCHOR_CACHE:
        return _ANCHOR_CACHE[resolved]
    try:
        lines = resolved.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        _ANCHOR_CACHE[resolved] = None
        return None
    found: set[str] = set()
    counts: dict[str, int] = {}
    for _, raw in outside_fences(lines):
        m = re.match(r"^(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$", raw)
        if not m:
            continue
        slug = slugify(m.group(2))
        if not slug:
            continue
        seen = counts.get(slug, 0)
        counts[slug] = seen + 1
        found.add(slug if seen == 0 else f"{slug}-{seen}")
    _ANCHOR_CACHE[resolved] = found
    return found


def inside_repo(path: Path) -> bool:
    try:
        path.resolve().relative_to(REPO_ROOT)
    except ValueError:
        return False
    return True


def adr_numbers(text: str) -> list[str]:
    """Return the ADR numbers linked from a stretch of metadata text."""
    numbers: list[str] = []
    for raw_target in LINK.findall(CODE_SPAN.sub("", text)):
        target = clean_link_target(raw_target)
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        rel, _, _ = target.partition("#")
        if not rel:
            continue
        m = ADR_FILE.match(Path(rel).name)
        if m and m.group(1) not in numbers:
            numbers.append(m.group(1))
    return numbers


def check(path: Path) -> tuple[list[str], dict[str, tuple[int, list[str]]]]:
    """Check one ADR. Returns its problems and its relationship claims."""
    problems: list[str] = []
    relations: dict[str, tuple[int, list[str]]] = {}

    def bad(line_no: int | None, msg: str) -> None:
        where = f"{path.name}:{line_no}" if line_no else path.name
        problems.append(f"{where}: {msg}")

    name_match = ADR_FILE.match(path.name)
    if not name_match:
        bad(None, "filename is not NNNN-lower-kebab-slug.md")
        return problems, relations
    number = name_match.group(1)

    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    header = FILE_HEADER.match(lines[0]) if lines else None
    skip = 1 if header and Path(header.group(1)).name == path.name else 0
    front, body_start, front_error = split_frontmatter(lines[skip:])
    body_start += skip
    front_line = 1 + skip

    if front_error == "unterminated":
        bad(front_line, "frontmatter block opens with --- but is never closed")
        return problems, relations
    if front_error == "missing":
        bad(front_line, "missing --- frontmatter block")
    elif not front:
        bad(front_line, "frontmatter block is empty")
    else:
        found = [
            (i, m.group(1))
            for i, raw in enumerate(front, start=front_line + 1)
            for m in [DOC_STATUS_LINE.match(raw.strip())]
            if m
        ]
        raw_keys = [
            i
            for i, raw in enumerate(front, start=front_line + 1)
            if raw.strip().startswith("documentation_status")
        ]
        if not raw_keys:
            bad(front_line, "frontmatter has no documentation_status")
        elif len(raw_keys) > 1:
            bad(
                raw_keys[1],
                "frontmatter has more than one documentation_status",
            )
        elif not found:
            bad(
                raw_keys[0],
                "documentation_status is not a bare value plus optional # comment",
            )
        elif found[0][1] not in DOC_STATUS:
            bad(
                found[0][0],
                f"documentation_status '{found[0][1]}' is not one of {sorted(DOC_STATUS)}",
            )

    visible_lines = outside_fences(lines)
    body = [(i, raw) for i, raw in visible_lines if i > body_start]

    titles = [i for i, raw in body if raw.startswith("# ")]
    if len(titles) != 1:
        bad(
            None, f"expected exactly one level-one heading, found {len(titles)}"
        )
    else:
        raw = lines[titles[0] - 1]
        m = TITLE.match(raw)
        if not m:
            bad(titles[0], "title is not '# ADR-NNNN: Title'")
        elif m.group(1) != number:
            bad(
                titles[0],
                f"title says ADR-{m.group(1)}, filename says {number}",
            )

    # Canonical metadata bullets, which live between the title and the first
    # section heading.
    fields: dict[str, tuple[int, str]] = {}
    duplicates: list[tuple[int, str]] = []
    for i, raw in body:
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

    if "Decision history" in fields:
        bad(
            fields["Decision history"][0],
            "Decision history must be a dated '## Decision history' section, not metadata",
        )

    for key, (line_no, _) in sorted(fields.items(), key=lambda kv: kv[1][0]):
        if key in ALLOWED_FIELDS or key == "Decision history":
            continue
        if VISIBLE_DOC_STATUS.search(key):
            continue
        bad(
            line_no,
            f"metadata field '{key}' is not canonical; "
            f"allowed keys are {sorted(ALLOWED_FIELDS)}, and lifecycle "
            "events belong in '## Decision history'",
        )

    status: str | None = None
    if "Status" not in fields:
        bad(None, "no canonical '- **Status:**' metadata field")
    else:
        line_no, status = fields["Status"]
        if status not in ADR_STATUS:
            bad(
                line_no, f"Status '{status}' is not one of {sorted(ADR_STATUS)}"
            )
        elif status == "superseded" and "Superseded by" not in fields:
            bad(
                line_no,
                "Status is superseded but no 'Superseded by' field names a successor",
            )

    if status != "superseded" and "Superseded by" in fields:
        bad(
            fields["Superseded by"][0],
            "'Superseded by' requires Status 'superseded'",
        )
    if status == "superseded" and "Superseded in part by" in fields:
        bad(
            fields["Superseded in part by"][0],
            "a partial supersession retains the predecessor's existing Status",
        )

    if "Date" not in fields:
        bad(None, "no canonical '- **Date:**' metadata field")
    elif not ISO_DATE.match(fields["Date"][1]):
        bad(fields["Date"][0], f"Date '{fields['Date'][1]}' is not YYYY-MM-DD")

    if "Ratified" in fields and not ISO_DATE.match(fields["Ratified"][1]):
        bad(
            fields["Ratified"][0],
            f"Ratified '{fields['Ratified'][1]}' is not YYYY-MM-DD",
        )

    for key, (line_no, _) in fields.items():
        if VISIBLE_DOC_STATUS.search(key):
            bad(
                line_no,
                "documentation_status is restated as a visible metadata field",
            )

    for key in sorted(RELATION_FIELDS.intersection(fields)):
        line_no, _ = fields[key]
        adr_targets = adr_numbers(field_block(lines, line_no))
        if not adr_targets:
            bad(line_no, f"'{key}' does not link a local ADR")
        else:
            relations[key] = (line_no, adr_targets)

    headings = [raw[3:].strip() for _, raw in body if raw.startswith("## ")]
    for section in REQUIRED_SECTIONS:
        count = headings.count(section)
        if count == 0:
            bad(None, f"missing required '## {section}' section")
        elif count > 1:
            bad(None, f"required section '## {section}' appears more than once")

    own_anchors = anchors(path)
    for i, raw in visible_lines:
        for raw_target in LINK.findall(CODE_SPAN.sub("", raw)):
            target = clean_link_target(raw_target)
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            rel, _, fragment = target.partition("#")
            if not rel:
                # A fragment-only link points into this same file.
                if (
                    fragment
                    and own_anchors is not None
                    and fragment.lower() not in own_anchors
                ):
                    bad(
                        i,
                        f"link fragment has no matching heading: {target}",
                    )
                continue
            destination = path.parent / rel
            if not destination.exists():
                bad(i, f"link target does not resolve: {target}")
                continue
            if not fragment:
                continue
            if destination.suffix.lower() != ".md" or not inside_repo(
                destination
            ):
                continue
            target_anchors = anchors(destination)
            if target_anchors is None:
                continue
            if fragment.lower() not in target_anchors:
                bad(i, f"link fragment has no matching heading: {target}")

    return problems, relations


def reciprocity(
    records: dict[str, dict[str, tuple[int, list[str]]]],
    paths: dict[str, Path],
) -> list[str]:
    """Check that every declared supersession is claimed from both sides."""
    problems: list[str] = []
    for number in sorted(records):
        relations = records[number]
        for key, mirror in RECIPROCAL_FIELDS.items():
            if key not in relations:
                continue
            line_no, targets = relations[key]
            for other in targets:
                if other not in records:
                    continue
                back = records[other].get(mirror)
                if back and number in back[1]:
                    continue
                problems.append(
                    f"{paths[number].name}:{line_no}: '{key}' names "
                    f"ADR-{other}, but {paths[other].name} has no "
                    f"'{mirror}' naming ADR-{number}"
                )
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
    records: dict[str, dict[str, tuple[int, list[str]]]] = {}
    problems: list[str] = []
    for path in files:
        m = ADR_FILE.match(path.name)
        file_problems, relations = check(path)
        if m:
            if m.group(1) in numbers:
                problems.append(
                    f"{path.name}: reuses the number of {numbers[m.group(1)].name}"
                )
            else:
                numbers[m.group(1)] = path
                records[m.group(1)] = relations
        problems.extend(file_problems)

    problems.extend(reciprocity(records, numbers))

    for problem in problems:
        print(problem)
    if problems:
        print(
            f"\n{len(problems)} problem(s) in {len(files)} ADR(s)",
            file=sys.stderr,
        )
        return 1
    print(f"{len(files)} ADRs OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
