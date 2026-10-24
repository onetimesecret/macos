---
name: issue332-ffi-entry
description: Issue 332 PR A unit 3, companion_markdown_parse_json at the C seam; why it takes objects and limits, what ADR-0012 wording admits it, and the license and CI facts the dependency brought
metadata:
  type: project
---

`companion_markdown_parse_json` (companion-ffi 0.44.0, 2026-10-24, uncommitted at write) takes text and length, object offsets and count, a dialect code and the three parse limits, so eight arguments under `allow(clippy::too_many_arguments)`.

- **Why objects and limits cross:** the production preview (`MarkdownPreviewView` on feat/markdown-dialects) calls the parser with attachment offsets and `CompositionLimits`, and issue 332 wants every Swift parser test to pass through the FFI unchanged. A text and dialect only seam would have to change in PR B.
- **Authority:** ADR-0012's base record is proposed; only Amendment 1 is accepted, and it lets the shell "hold visible ink before sealing". The parse call is neither the ingress nor an egress in that inventory. No ADR was edited.
- **Reply shape:** the document JSON, `{"error": <ParseError>}` for a refused page, null for bad arguments or a contained panic.
- **License:** finl_unicode declares `Unicode-DFS-2016` but ships the UNICODE LICENSE V3 text; deny.toml allows the declared id.
- **CI gap:** the Linux job's `-p` lists omit companion-markdown, so its tests run only in the macOS platform job until someone adds it.

**How to apply:** PR B's Swift decoder calls this entry with `withCString` (text must be non-null even when empty) and decodes the refusal with a synthesized `{error: MarkdownParseError}`. See [[issue332-spec-corpus]].
