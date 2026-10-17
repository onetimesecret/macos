"""Explicit C configurations; fork core is never labeled CommonMark 0.31.2."""

SOURCEPOS = 1 << 1
SMART = 1 << 10
DOUBLE = 1 << 14
SPANS = 1 << 20
GFM = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]
WRAPPER = ["table", "strikethrough", "tasklist"]


def mode(candidate, profile, options, extensions, basis):
    return dict(
        candidate=candidate,
        profile=profile,
        parse_options=options,
        extensions=extensions,
        basis=basis,
    )


MODES = {
    "cm-core": mode(
        "commonmark", "core", 0, [], "Official CommonMark 0.31.2, no extensions"
    ),
    "cm-smart": mode(
        "commonmark",
        "smart",
        SMART,
        [],
        "Selected SMART toggle, not a complete wrapper configuration",
    ),
    "legacy-core": mode(
        "gfm-official",
        "core",
        0,
        [],
        "Historical GFM core, no extensions; not CommonMark 0.31.2",
    ),
    "legacy-gfm": mode(
        "gfm-official", "gfm", 0, GFM, "Historical GFM with five extensions"
    ),
    "legacy-double": mode(
        "gfm-official",
        "gfm-double",
        DOUBLE,
        GFM,
        "Selected DOUBLE_TILDE toggle on legacy-gfm",
    ),
    "swift-core": mode(
        "gfm",
        "core",
        0,
        [],
        "Pinned fork core, no extensions; not CommonMark 0.31.2",
    ),
    "swift-gfm": mode(
        "gfm",
        "gfm",
        0,
        GFM,
        "Pinned fork with five extensions; old-lab GFM configuration",
    ),
    "swift-double": mode(
        "gfm",
        "gfm-double",
        DOUBLE,
        GFM,
        "Selected DOUBLE_TILDE toggle on swift-gfm",
    ),
    "swift-preview": mode(
        "gfm",
        "preview",
        SPANS | SOURCEPOS,
        WRAPPER,
        "Full current preview C invocation: Swift [.disableSmartOpts]",
    ),
    "swift-preview-spans-off": mode(
        "gfm",
        "preview-spans-off",
        SOURCEPOS,
        WRAPPER,
        "Only TABLE_SPANS removed from current preview",
    ),
    "swift-default": mode(
        "gfm",
        "wrapper-default",
        SPANS | SOURCEPOS | SMART,
        WRAPPER,
        "Full C invocation for Swift ParseOptions []",
    ),
    "swift-gfm-spans": mode(
        "gfm",
        "gfm-spans",
        SPANS,
        GFM,
        "Only TABLE_SPANS added to swift-gfm; not the wrapper configuration",
    ),
    "swift-preview-double": mode(
        "gfm",
        "preview-double",
        SPANS | SOURCEPOS | DOUBLE,
        WRAPPER,
        "Only DOUBLE_TILDE added to current preview; not a Swift ParseOptions switch",
    ),
    "swift-preview-no-sourcepos": mode(
        "gfm",
        "preview-no-sourcepos",
        SPANS,
        WRAPPER,
        "Only SOURCEPOS removed from current preview",
    ),
}
