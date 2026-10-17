"""Structural oracles authored from syntax, inspected APIs, and saved standards examples."""

import json
import re
from html import escape
from pathlib import Path
from urllib.parse import quote

from profiles import DOUBLE, SMART, SPANS

LAB = Path(__file__).resolve().parent.parent
ASCII = "OTSAttachment0123456789ABCDEF0123456789ABCDEF0Z"
TOKENS = {"ascii": ASCII, "so": "\ufffc"}


def n(kind, *children, literal=None, **properties):
    value = {"type": kind}
    if literal is not None:
        value["literal"] = literal
    if properties:
        value["properties"] = properties
    if children:
        value["children"] = list(children)
    return value


def text(value):
    return n("text", literal=value)


def p(*children):
    return n("paragraph", *children)


def doc(*children):
    return n("document", *children)


def emph(value):
    return n("emph", text(value))


def link(label, destination):
    return n("link", text(label), destination=destination, title="")


def html_text(value):
    return escape(value, quote=False).replace('"', "&quot;")


def expected_html(node, mode, in_header=False):
    kind = node["type"]
    props = node.get("properties", {})
    children = node.get("children", [])
    rendered = "".join(
        expected_html(child, mode, in_header) for child in children
    )
    if kind == "document":
        return rendered
    if kind == "paragraph":
        return "<p>" + rendered + "</p>\n"
    if kind == "text":
        return html_text(node["literal"])
    if kind == "softbreak":
        return "\n"
    if kind in ("emph", "strong", "strikethrough"):
        tag = {"emph": "em", "strong": "strong", "strikethrough": "del"}[kind]
        return f"<{tag}>" + rendered + f"</{tag}>"
    if kind == "attribute":
        return rendered
    if kind == "link":
        url = quote(props["destination"], safe="/:#?=&%+@.-_~")
        return '<a href="' + html_text(url) + '">' + rendered + "</a>"
    if kind == "code_block":
        return "<pre><code>" + html_text(node["literal"]) + "</code></pre>\n"
    if kind in ("html_block", "html_inline"):
        value = node["literal"]
        if "tagfilter" in mode["extensions"]:
            value = re.sub(
                r"<(?=/?textarea(?:\s|>|$))", "&lt;", value, flags=re.IGNORECASE
            )
        return value
    if kind == "table":
        header, *rows = children
        head = expected_html(header, mode)
        body = (
            "<tbody>\n"
            + "".join(expected_html(row, mode) for row in rows)
            + "</tbody>\n"
            if rows
            else ""
        )
        return "<table>\n" + head + body + "</table>\n"
    if kind == "table_header":
        return (
            "<thead>\n<tr>\n"
            + "".join(expected_html(child, mode, True) for child in children)
            + "</tr>\n</thead>\n"
        )
    if kind == "table_row":
        return "<tr>\n" + rendered + "</tr>\n"
    if kind == "table_cell":
        colspan, rowspan = props.get("colspan", 1), props.get("rowspan", 1)
        if not colspan or not rowspan:
            return ""
        tag = "th" if in_header else "td"
        attrs = (f' colspan="{colspan}"' if colspan > 1 else "") + (
            f' rowspan="{rowspan}"' if rowspan > 1 else ""
        )
        return f"<{tag}{attrs}>" + rendered + f"</{tag}>\n"
    raise ValueError("Unspecified HTML expectation: " + kind)


def cases(mode):
    swift = mode["candidate"] == "gfm"
    legacy = mode["candidate"] == "gfm-official"
    spans = bool(mode["parse_options"] & SPANS)
    double_only = bool(mode["parse_options"] & DOUBLE)
    smart = bool(mode["parse_options"] & SMART)
    table_enabled = "table" in mode["extensions"]
    strike_enabled = "strikethrough" in mode["extensions"]
    rows = []

    def add(identifier, source, ast, reason, oracle=None):
        rows.append(
            dict(
                id=identifier,
                markdown=source,
                expected_ast=ast,
                expected_html=expected_html(ast, mode),
                reason=reason,
                official_oracle=oracle,
            )
        )

    def tilde(identifier, value, count):
        delimiters = "~" * count
        source = "a " + delimiters + value + delimiters + " b\n"
        enabled = (
            strike_enabled
            and count in (1, 2)
            and not (count == 1 and double_only)
        )
        ast = (
            doc(p(text("a "), n("strikethrough", text(value)), text(" b")))
            if enabled
            else doc(p(text(source.rstrip("\n"))))
        )
        add(
            identifier,
            source,
            ast,
            "Only single/double runs are eligible, and DOUBLE_TILDE rejects single runs.",
        )

    for count in (1, 2, 3):
        tilde(f"tilde-{count}", "note", count)
        for spelling, token in TOKENS.items():
            tilde(f"tilde-{count}-{spelling}", token, count)
    add(
        "tilde-fence-control",
        "~~~\ncode\n~~~\n",
        doc(n("code_block", literal="code\n")),
        "A line-initial triple-tilde fence is a code block, not inline strikethrough.",
    )

    def attribute(identifier, label, payload, rich=False):
        source = (
            "^["
            + ("*" + label + "*" if rich else label)
            + "]("
            + payload
            + ")\n"
        )
        child = emph(label) if rich else text(label)
        if swift:
            ast = doc(p(n("attribute", child, attributes=payload)))
        elif payload == "color: red":
            ast = (
                doc(p(text("^["), child, text("](color: red)")))
                if rich
                else doc(p(text(source.rstrip("\n"))))
            )
        else:
            resource = n("link", child, destination=payload, title="")
            ast = doc(p(text("^"), resource))
        add(
            identifier,
            source,
            ast,
            "The pinned fork recognizes ATTRIBUTE in its core; other candidates apply ordinary bracket/link rules.",
        )

    attribute("attribute-spaced-payload", "note", "color: red")
    attribute("attribute-rich-label", "note", "color: red", rich=True)
    attribute("attribute-linklike", "note", "key")
    attribute("attribute-empty-payload", "note", "")
    add(
        "attribute-unclosed",
        "^[note]\n",
        doc(p(text("^[note]"))),
        "No attribute payload or reference is present.",
    )
    add(
        "attribute-escaped-caret",
        "\\^[note](key)\n",
        doc(p(text("^"), link("note", "key"))),
        "An escaped caret does not introduce an attribute, even in the pinned core.",
    )
    for spelling, token in TOKENS.items():
        attribute("attribute-label-" + spelling, token, "key")
        attribute("attribute-payload-" + spelling, "note", token)

    def cell(value, col=1, row=1):
        props = dict(colspan=col, rowspan=row) if swift else {}
        return n("table_cell", *([text(value)] if value else []), **props)

    def table(
        identifier, header, bodies, expected_header, expected_rows, reason
    ):
        source = header + "\n| --- | --- | --- |\n" + "\n".join(bodies) + "\n"
        if table_enabled:
            ast = doc(
                n(
                    "table",
                    n("table_header", *expected_header),
                    *(n("table_row", *row) for row in expected_rows),
                )
            )
        else:
            children = []
            for line in source.rstrip("\n").splitlines():
                if children:
                    children.append(n("softbreak"))
                children.append(
                    text(line.replace("---", "—") if smart else line)
                )
            ast = doc(p(*children))
        add(identifier, source, ast, reason)

    header = "| A | B | C |"
    h = [cell("A"), cell("B"), cell("C")]
    table(
        "table-ordinary",
        header,
        ["| left | middle | right |"],
        h,
        [[cell("left"), cell("middle"), cell("right")]],
        "Ordinary cells provide a non-span control.",
    )
    table(
        "table-colspan-two",
        header,
        ["| left || right |"],
        h,
        [[cell("left", 2), cell("", 0), cell("right")]]
        if spans
        else [[cell("left"), cell(""), cell("right")]],
        "An immediately empty cell is a colspan filler only with TABLE_SPANS.",
    )
    table(
        "table-colspan-three",
        header,
        ["| wide |||"],
        h,
        [[cell("wide", 3), cell("", 0), cell("", 0)]]
        if spans
        else [[cell("wide"), cell(""), cell("")]],
        "The API must report a numeric colspan of three, not just a boolean marker.",
    )
    table(
        "table-header-colspan",
        "| A || C |",
        ["| left | middle | right |"],
        [cell("A", 2), cell("", 0), cell("C")]
        if spans
        else [cell("A"), cell(""), cell("C")],
        [[cell("left"), cell("middle"), cell("right")]],
        "Header spans are checked through APIs and HTML because XML omits their metadata.",
    )
    table(
        "table-rowspan",
        header,
        ["| top | mid | right |", "| ^ | low | end |"],
        h,
        [
            [cell("top", row=2), cell("mid"), cell("right")],
            [cell("", row=0), cell("low"), cell("end")],
        ]
        if spans
        else [
            [cell("top"), cell("mid"), cell("right")],
            [cell("^"), cell("low"), cell("end")],
        ],
        "A caret-only cell extends the previous cell and is emptied only with TABLE_SPANS.",
    )
    table(
        "table-combined-span",
        header,
        ["| top || right |", "| ^ || next |"],
        h,
        [
            [cell("top", 2, 2), cell("", 0), cell("right")],
            [cell("", 2, 0), cell("", 0), cell("next")],
        ]
        if spans
        else [
            [cell("top"), cell(""), cell("right")],
            [cell("^"), cell(""), cell("next")],
        ],
        "Combined row/column spans retain filler nodes but suppress them in HTML.",
    )
    table(
        "table-empty-width-control",
        header,
        ["| left |   | right |"],
        h,
        [[cell("left"), cell(""), cell("right")]],
        "A wider whitespace cell is empty text, not the immediate-pipe span syntax.",
    )
    table(
        "table-caret-text-control",
        header,
        ["| top | mid | right |", "| ^ note | low | end |"],
        h,
        [
            [cell("top"), cell("mid"), cell("right")],
            [cell("^ note"), cell("low"), cell("end")],
        ],
        "Caret plus other text is not a rowspan marker.",
    )
    for spelling, token in TOKENS.items():
        table(
            "table-span-token-" + spelling,
            header,
            ["| " + token + " || right |"],
            h,
            [[cell(token, 2), cell("", 0), cell("right")]]
            if spans
            else [[cell(token), cell(""), cell("right")]],
            "The token remains text inside the spanning cell; no native object node is introduced.",
        )

    def html_block(source):
        return n("html_block", literal=source)

    def textarea(identifier, source, modern, historical, oracle=None):
        add(
            identifier,
            source,
            historical if legacy else modern,
            "Modern/pinned scanners treat textarea as type-1 HTML; the historical scanner does not. Tagfilter is a separate rendering extension.",
            oracle,
        )

    source = "<textarea>\n*inside*\n</textarea>\n*after*\n"
    textarea(
        "textarea-close-boundary",
        source,
        doc(
            html_block("<textarea>\n*inside*\n</textarea>\n"), p(emph("after"))
        ),
        doc(html_block(source)),
    )
    source = "lead\n<textarea>\n*inside*\n</textarea>\n*after*\n"
    textarea(
        "textarea-paragraph-interruption",
        source,
        doc(
            p(text("lead")),
            html_block("<textarea>\n*inside*\n</textarea>\n"),
            p(emph("after")),
        ),
        doc(
            p(
                text("lead"),
                n("softbreak"),
                n("html_inline", literal="<textarea>"),
                n("softbreak"),
                emph("inside"),
                n("softbreak"),
                n("html_inline", literal="</textarea>"),
                n("softbreak"),
                emph("after"),
            )
        ),
    )
    source = "<TEXTAREA>\n\n*inside*\n\n</TEXTAREA>\n\n*after*\n"
    textarea(
        "textarea-uppercase-blank-boundaries",
        source,
        doc(
            html_block("<TEXTAREA>\n\n*inside*\n\n</TEXTAREA>\n"),
            p(emph("after")),
        ),
        doc(
            html_block("<TEXTAREA>\n"),
            p(emph("inside")),
            html_block("</TEXTAREA>\n"),
            p(emph("after")),
        ),
    )

    cm = json.loads((LAB / "results/commonmark-0.31.2-spec.json").read_text())
    gf = json.loads((LAB / "results/gfm-official-examples.json").read_text())
    oracle = lambda family, item: dict(
        family=family,
        example=item["example"],
        expected_html=item["html"],
        section=item["section"],
    )
    item = cm[170]
    textarea(
        "official-cm-171",
        item["markdown"],
        doc(html_block(item["markdown"])),
        doc(
            html_block("<textarea>\n"),
            p(emph("foo")),
            p(emph("bar")),
            html_block("</textarea>\n"),
        ),
        oracle("CommonMark 0.31.2", item),
    )
    item = cm[353]
    ast = (
        doc(
            p(text("*$*alpha.")),
            p(emph("£"), text("bravo.")),
            p(emph("€"), text("charlie.")),
        )
        if mode["candidate"] != "commonmark"
        else doc(
            p(text("*$*alpha.")), p(text("*£*bravo.")), p(text("*€*charlie."))
        )
    )
    add(
        "official-cm-354",
        item["markdown"],
        ast,
        "ASCII dollar is punctuation in all candidates; Unicode currency symbols distinguish P from P/S.",
        oracle("CommonMark 0.31.2", item),
    )
    item = next(row for row in gf if row["example"] == 491)
    children = [n("strikethrough", text("Hi")), text(" Hello, ")]
    if not double_only:
        children += [n("strikethrough", text("there")), text(" world!")]
    else:
        children[-1]["literal"] += "~there~ world!"
    ast = (
        doc(p(*children))
        if strike_enabled
        else doc(p(text("~~Hi~~ Hello, ~there~ world!")))
    )
    add(
        "official-gfm-491",
        item["markdown"],
        ast,
        "The published example explicitly uses both single and double tildes.",
        oracle("GFM 0.29-gfm", item),
    )
    item = next(row for row in gf if row["example"] == 492)
    add(
        "official-gfm-492",
        item["markdown"],
        doc(p(text("This ~~has a")), p(text("new paragraph~~."))),
        "Strikethrough never crosses this paragraph boundary.",
        oracle("GFM 0.29-gfm", item),
    )
    item = next(row for row in gf if row["example"] == 493)
    add(
        "official-gfm-493",
        item["markdown"],
        doc(p(text("This will ~~~not~~~ strike."))),
        "Triple inline tilde runs remain literal in the published example.",
        oracle("GFM 0.29-gfm", item),
    )
    add(
        "smart-option-control",
        '"note" -- ...\n',
        doc(p(text("“note” – …" if smart else '"note" -- ...'))),
        "SMART is on in the wrapper default, but off in the actual preview invocation.",
    )
    add(
        "autolink-extension-control",
        "www.example.com\n",
        doc(p(link("www.example.com", "http://www.example.com")))
        if "autolink" in mode["extensions"]
        else doc(p(text("www.example.com"))),
        "The actual Swift wrapper extension set does not include autolink.",
    )
    return rows
