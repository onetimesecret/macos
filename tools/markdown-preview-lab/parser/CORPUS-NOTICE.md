# Official-example attribution

The downloaded specifications and their extracted examples are third-party
material, separate from the lab's original code. Their licensing is not replaced
by the repository's license.

## CommonMark 0.31.2

CommonMark Spec, by John MacFarlane, version 0.31.2 (2024-01-28).
Source: <https://spec.commonmark.org/0.31.2/>;
example download: <https://spec.commonmark.org/0.31.2/spec.json>.
License: [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/).
The pinned cmark source's `test/spec.txt` front matter identifies the author,
version, date, and license.

`results/commonmark-0.31.2-spec.json` is the unmodified download.
`results/commonmark-corpus-results.jsonl` includes those examples and expected
HTML alongside locally generated parser output and comparison fields. This
packaging changes the representation, not the attribution of the source text.

## GitHub Flavored Markdown 0.29-gfm

GitHub Flavored Markdown Spec, version 0.29-gfm (2019-04-06).
Source: <https://github.github.com/gfm/>.
The downloaded page's license notice identifies it as based on the CommonMark
Spec by John MacFarlane and licensed under
[Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/).
That notice remains in `results/gfm-0.29-spec.html`.

`results/gfm-0.29-spec.html` is the unmodified download.
`results/gfm-official-examples.json` extracts the numbered examples, decodes
HTML entities, and converts displayed tab arrows to tabs.
`results/gfm-corpus-results.jsonl`, `results/gfm-official-corpus-results.jsonl`,
and the official-example excerpts in `results/summary.json` add local parser
output and comparison fields. Those example-containing adaptations are provided
under the same CC-BY-SA 4.0 license, with the source attribution above.

## Scope

This notice covers retained specification/example material and its
example-containing adaptations. It is not a completed dependency or native-app
redistribution review. Parser source checkouts and compiled binaries are ignored
local build inputs, not part of this research commit. Their original `COPYING`
files remain in those checkouts. Provenance and download checksums are recorded
in `results/provenance.json` and the lab README.
