"""Hand-authored structural expectations, not snapshots learned from a parser."""

TOKENS = {
    "ascii": "OTSAttachment0123456789ABCDEF0123456789ABCDEF0Z",
    "so": "\ufffc",
}


def n(kind, *children, **attributes):
    node = {"type": kind}
    if attributes:
        node["attributes"] = attributes
    if children:
        node["children"] = list(children)
    return node


def text(value):
    return {"type": "text", "literal": value}


def raw(kind, value):
    return {"type": kind, "literal": value}


def paragraph(*children):
    return n("document", n("paragraph", *children))


def emph(value):
    return n("emph", text(value))


def resource(kind, label, destination, title=""):
    return n(kind, text(label), destination=destination, title=title)


def cases(dialect, token_kind):
    p = TOKENS[token_kind]
    ps = dialect == "commonmark" and token_kind == "so"
    gfm = dialect == "gfm"
    url = "https://example.com/r"
    rows = []

    def add(name, source, expected, reason):
        rows.append(
            {
                "id": name,
                "dialect": dialect,
                "token_kind": token_kind,
                "token": p,
                "markdown": source,
                "expected_ast": expected,
                "reason": reason,
            }
        )

    def literal(name, source, reason):
        add(name, source, paragraph(text(source)), reason)

    add(
        "underscore-after",
        "_note_" + p,
        paragraph(emph("note"), text(p))
        if ps
        else paragraph(text("_note_" + p)),
        "Only the P/S classifier makes the trailing object punctuation for underscore flanking.",
    )
    add(
        "underscore-before",
        p + "_note_",
        paragraph(text(p), emph("note"))
        if ps
        else paragraph(text(p + "_note_")),
        "Mirror the underscore boundary on the other side.",
    )
    add(
        "underscore-both",
        p + "_note_" + p,
        paragraph(text(p), emph("note"), text(p))
        if ps
        else paragraph(text(p + "_note_" + p)),
        "Both boundaries depend on the token character class.",
    )
    add(
        "star-interior",
        "a*" + p + "*b",
        paragraph(text("a*" + p + "*b"))
        if ps
        else paragraph(text("a"), emph(p), text("b")),
        "A symbol between asterisks changes flanking when surrounded by letters.",
    )
    add(
        "star-before",
        p + "*note*",
        paragraph(text(p), emph("note")),
        "Asterisks can delimit emphasis beside either spelling here.",
    )
    add(
        "star-after",
        "*note*" + p,
        paragraph(emph("note"), text(p)),
        "Asterisk closing boundary with an adjacent object.",
    )
    add(
        "star-around",
        "*" + p + "*",
        paragraph(emph(p)),
        "Object spelling is ordinary text inside emphasis.",
    )
    for name, source, children in (
        (
            "link-before-bracket",
            p + "[label](" + url + ")",
            [text(p), resource("link", "label", url)],
        ),
        (
            "link-after-bracket",
            "[label](" + url + ")" + p,
            [resource("link", "label", url), text(p)],
        ),
        ("link-label", "[" + p + "](" + url + ")", [resource("link", p, url)]),
        (
            "image-before-bracket",
            p + "![alt](" + url + ")",
            [text(p), resource("image", "alt", url)],
        ),
        (
            "image-after-bracket",
            "![alt](" + url + ")" + p,
            [resource("image", "alt", url), text(p)],
        ),
        ("image-alt", "![" + p + "](" + url + ")", [resource("image", p, url)]),
        (
            "image-alt-order",
            "![left" + p + "right](" + url + ")",
            [resource("image", "left" + p + "right", url)],
        ),
        (
            "image-bang-gap",
            "!" + p + "[alt](" + url + ")",
            [text("!" + p), resource("link", "alt", url)],
        ),
        (
            "link-destination",
            "[label](https://example.com/" + p + ")",
            [resource("link", "label", "https://example.com/" + p)],
        ),
        (
            "image-destination",
            "![alt](https://example.com/" + p + ")",
            [resource("image", "alt", "https://example.com/" + p)],
        ),
        (
            "link-title",
            "[label](" + url + ' "' + p + '")',
            [resource("link", "label", url, p)],
        ),
        (
            "angle-autolink",
            "<https://example.com/" + p + ">",
            [
                resource(
                    "link",
                    "https://example.com/" + p,
                    "https://example.com/" + p,
                )
            ],
        ),
    ):
        add(
            name,
            source,
            paragraph(*children),
            "Check text, resource metadata, and bracket structure separately.",
        )
    for name, label in (
        ("link-label-destination-gap", "[label]"),
        ("image-label-destination-gap", "![alt]"),
    ):
        source = label + p + "(" + url + ")"
        add(
            name,
            source,
            paragraph(
                text(label + p + "("), resource("link", url, url), text(")")
            )
            if gfm
            else paragraph(text(source)),
            "The inline resource syntax is broken; GFM still autolinks the exposed URL.",
        )
    for name, prefix, suffix in (
        ("autolink-www-domain", "www.example.com", ""),
        ("autolink-www-path", "www.example.com/", ""),
        ("autolink-http-domain", "https://example.com", ""),
        ("autolink-http-path", "https://example.com/", ""),
        ("autolink-trailing-period", "www.example.com/", "."),
    ):
        value = prefix + p
        destination = ("http://" if prefix.startswith("www.") else "") + value
        children = [resource("link", value, destination)] + (
            [text(suffix)] if suffix else []
        )
        add(
            name,
            value + suffix,
            paragraph(*children) if gfm else paragraph(text(value + suffix)),
            "CommonMark has no bare extended autolink; GFM includes either token in this URL.",
        )
    email = "person@example.com"
    add(
        "autolink-email",
        email + p,
        paragraph(resource("link", email, "mailto:" + email), text(p))
        if gfm and token_kind == "so"
        else paragraph(resource("link", email + p, "mailto:" + email + p))
        if gfm
        else paragraph(text(email + p)),
        "The email scanner stops before So, unlike the www/http scanner.",
    )
    header = "| x | y |\n| --- | --- |\n"
    for name, body, cells in (
        ("table-pipe-after", "| " + p + "| tail |\n", [p, "tail"]),
        ("table-pipe-before", "| head |" + p + " |\n", ["head", p]),
        (
            "table-escaped-pipe",
            "| a" + p + "\\|b | c |\n",
            ["a" + p + "|b", "c"],
        ),
        ("table-excess-cell", "| a | b | " + p + " |\n", ["a", "b"]),
    ):
        table = n(
            "document",
            n(
                "table",
                n(
                    "table_header",
                    n("table_cell", text("x")),
                    n("table_cell", text("y")),
                ),
                n(
                    "table_row",
                    *(n("table_cell", text(cell)) for cell in cells),
                ),
            ),
        )
        plain = paragraph(
            text("| x | y |"),
            n("softbreak"),
            text("| --- | --- |"),
            n("softbreak"),
            text(body.rstrip("\n").replace("\\|", "|")),
        )
        add(
            name,
            header + body,
            table if gfm else plain,
            "GFM splits table cells; excess cells are absent from its AST. CommonMark keeps paragraph text.",
        )
    for name, tag, valid in (
        ("html-tag-name", "<" + p + ">", token_kind == "ascii"),
        (
            "html-attribute-name",
            "<span data-" + p + "=x>",
            token_kind == "ascii",
        ),
        ("html-attribute-double", '<span data-x="' + p + '">', True),
        ("html-attribute-single", "<span data-x='" + p + "'>", True),
        ("html-attribute-unquoted", "<span data-x=" + p + ">", True),
        ("html-comment-inline", "<!--" + p + "-->", True),
        ("html-src", '<img src="https://example.com/' + p + '">', True),
        (
            "html-srcset",
            '<img srcset="https://example.com/' + p + ' 1x">',
            True,
        ),
        ("html-css-url", '<span style="background:url(' + p + ')">', True),
        ("html-alt", '<img src="x" alt="left' + p + 'right">', True),
    ):
        source = "a " + tag + " b"
        add(
            name,
            source,
            paragraph(text("a "), raw("html_inline", tag), text(" b"))
            if valid
            else paragraph(text(source)),
            "Valid raw HTML is one opaque literal, not parsed attributes or object nodes.",
        )
    for name, source in (
        ("html-comment-block", "<!--" + p + "-->\n"),
        ("html-block-attribute", '<div data-x="' + p + '">\nbody\n</div>\n'),
        ("html-script-content", "<script>" + p + "</script>\n"),
    ):
        add(
            name,
            source,
            n("document", raw("html_block", source)),
            "Block HTML, including removed-element candidates, is opaque at this AST boundary.",
        )
    add(
        "reference-destination",
        "[label][ref]\n\n[ref]: https://example.com/" + p + "\n",
        paragraph(resource("link", "label", "https://example.com/" + p)),
        "Reference resolution moves the token to link metadata, not visible text.",
    )
    return rows
