# cmark-gfm 0.29.0.gfm.13, vendored

Written by `scripts/vendor-cmark.sh`; `scripts/vendor-cmark.sh --check` verifies
this file, `upstream/`, `patches/` and `prefix.h` offline. Do not edit by hand.

- Repository: https://github.com/github/cmark-gfm
- Tag: 0.29.0.gfm.13
- Commit: 587a12bb54d95ac37241377e6ddc93ea0e45439b
- Patches, applied in order with `git apply` to the files of that commit:
  - `patches/0001-autolink-fix-unsigned-pointer-overflow-in-validate_protocol.patch` (SHA-256 cd8c4af910e044ae17435c6ae83b3747424660c92d700e10daeb3bd6864a83cf)
  - `patches/0002-autolink-end-extended-autolinks-at-object-placeholders.patch` (SHA-256 8cfd54307119758094199abdf1c73dae91966aa34fa11e45588b80a2b3446144)
  - `patches/0003-table-share-one-cell-budget-across-a-parse.patch` (SHA-256 a1692ace5edcbc57e3b7f86404930b28f760ed8aea751f22b58673c5e21aac14)

`0001` is upstream master commit 46829933c318b4c3108581e82469fe4474f744a9, exported with
`git format-patch`: the fix for the unsigned pointer wrap in
`validate_protocol` (`extensions/autolink.c`). The script compares its patch
id with that commit's. `0002` and `0003` are Onetime Pad's own. `0002`: every
plane 16 scalar, U+100000..U+10FFFF, ends a www or http extended autolink and
is no host character, on every page, because the preview's sealed-object
placeholders are drawn from that plane; extended autolinks over plane 16 text
therefore differ from stock cmark-gfm, which the corpus comparison does not
cover. `0003`: every table of a parse shares one cell budget, which the shim
sets (`extensions/table.c`, `extensions/table.h`).

## Kept files

`upstream/` has `COPYING` and the files from upstream `src/` and
`extensions/` that the SHA-256 list below names, under their upstream paths.

The shim parses with the five core extensions and walks the tree, which needs
the block and inline parsers, the node, buffer, UTF-8, entity, map and
reference code, the extension registry and plugin code, `footnotes.c` (the
block parser calls it with footnotes off too), the pregenerated `scanners.c`
and `extensions/ext_scanners.c` (re2c is not needed), and
`extensions/core-extensions.c` with the table, strikethrough, autolink,
tagfilter and tasklist extensions. `arena.c` stays because `table.c` calls
`cmark_arena_pop`. `cmark.c` defines the default allocator and also
`cmark_markdown_to_html`, which calls `cmark_render_html`, so `html.c` and
the two escapers it calls stay and the target links with no undefined symbol.
Left out: `main.c` (the command line tool) and the other renderers
(`commonmark.c`, `latex.c`, `man.c`, `plaintext.c`, `xml.c`, `render.c`),
which no kept file calls.

`generated/` stands in for what CMake writes (`cmark-gfm_export.h`,
`cmark-gfm_version.h`, `config.h`); no kept file includes the extensions'
export header, so it has no stand-in. `prefix.h` defines every external
symbol of a build of `upstream/` to `otsgfm_<name>`, and the target
force-includes it into every C file.

## SHA-256 before patching

| File | SHA-256 |
| --- | --- |
| `upstream/extensions/autolink.c` | ce87706761fbdd21ad4019f070731f9e2e19538c66933a3a6266466074f327e8 |
| `upstream/extensions/table.c` | 2f021e64aed145578322c767475399138e76b94ec07599696a5a15ee14133ed1 |
| `upstream/extensions/table.h` | e054b8c846fcedff9b02981caa518c01ac93c09237267eb57f6959fecaf1fced |

## SHA-256 after patching

```
c22e885f33b821bddb24cf007145e5540655b6c0f403e49e6c76a93c28e6d9a9  upstream/COPYING
b19ddf033da8d6560d7143b2e1c6a365e9615c81cbeddedbaf342f9c3ed7925c  upstream/extensions/autolink.c
32b32d557c19d18c30b8fa01a5b8475f910a3fae48ef78fbde4e089c48f1e216  upstream/extensions/autolink.h
0430e1348124d7f84576ec626ef8d49d38f5b41bd1ea7708dca5967b5e49cfae  upstream/extensions/cmark-gfm-core-extensions.h
281a5514746d541eea3a26c6ce55d35c9594d62661396a458b4385be698436a2  upstream/extensions/core-extensions.c
449e5bff8031b213ae43b353900b5b3f11f0123a36379ef634f7ed5fe05b4b6a  upstream/extensions/ext_scanners.c
a7fa1df781d227e84a0f41db22a8c544037611241dad82fed2c6e1e16acf7780  upstream/extensions/ext_scanners.h
47ce340067b63eb062b2b6b40212f86e7734627b0affb82902a935125e88927e  upstream/extensions/strikethrough.c
76957f0e97d1e51227b05a48efaa879a349c7123b74510a2741d832435096644  upstream/extensions/strikethrough.h
3a32400214e4936d10ee068f10d5dc6f647e7649524eba60449e15806751dacf  upstream/extensions/table.c
dd30e3db80fbd241943e66cdbe0b53c1ec88cae87a7904a9fa4ec8cad0f9db9c  upstream/extensions/table.h
9657363955756efc83539a5a852d37545853c2893bbcb7d70d31a4f31b4e27d0  upstream/extensions/tagfilter.c
bf5a55e109c9fa98be9499adf95992ba5281ded4a3dcc34633b2a45446530f19  upstream/extensions/tagfilter.h
9869288ae527b81849b631051d79ca73931d25dc1ef43e53268f9c6e54c04c29  upstream/extensions/tasklist.c
a789f46d72bfd702a6bcbfdf2377ccd335256c020843c21e21706acea86a0560  upstream/extensions/tasklist.h
cd815bc59d20838782f0aaf5c8ca09b220fac85200fd38441861f2a7b3332896  upstream/src/arena.c
464266209ed2c94b42ba6c9c4d2768f0f7bda3d668f4e5fa86bcf47b18b7f0ff  upstream/src/blocks.c
3f458b3947a6595c06963e52489e0e0fc8b43e1edb316a192a42df3fd986b2d5  upstream/src/buffer.c
8341c1780679b29b20127af8a52de5b97886660d8bc7cf2ad7c21edff7ceb123  upstream/src/buffer.h
37726f404907e68a2c044c78f7c1559e46fbaf91f691989985264ddc58251579  upstream/src/case_fold_switch.inc
33ee10c88d18a91e943cb7b418e51bf661ae371dd74d8f51cefc802620df1164  upstream/src/chunk.h
58f47cef48d08915d51ed37990b60e7fe96af33c5d726e8654cc3770a5f62476  upstream/src/cmark-gfm-extension_api.h
6502e5b58a822af20e2540819fb2c05cfcd8446c1c837881892da57f29d3cd88  upstream/src/cmark-gfm.h
d9fd116cf77890dab19f7f29f1d261865454cf4e51d57ec2d21f7592b211bfde  upstream/src/cmark.c
556d662fa2f1513630bc1d76023e1e17bb8c185eab1b6936c14e59af0c3c3148  upstream/src/cmark_ctype.c
fd4966af7e19a5fe826e4c1376e1b9b0269a86b88912696299cecc8f1957bde3  upstream/src/cmark_ctype.h
3932dfa630067813f47be6ae0072e1645c1183bde41140b51443f50857c88909  upstream/src/entities.inc
da853b3ca7f27bbabadb48596457243489dbeb1782a385795733ab8066dd181b  upstream/src/footnotes.c
cd3137246058d58b3325969f96472b8e3c39ae2de93e0b07fddfb22bad952401  upstream/src/footnotes.h
1de38a17d59e2df294ea949b0ac5982a016f582b507aaf1cad1278b8c27704e9  upstream/src/houdini.h
812efd5dfa898335f43b09fd101d00574d9af0476146961ee82f8c8195c1e8a4  upstream/src/houdini_href_e.c
14c268cbd8707d2ec01eec726780886cb27d85caf6fff79455e687c6d774c1c7  upstream/src/houdini_html_e.c
5738d88a576c807c99905405833057411329ce61fa784f4db3a55d5fb5f3ac7b  upstream/src/houdini_html_u.c
e2f61240a135e34d595cde1fae9063bbc3ff033720eb52d3acb77fde3cddeb29  upstream/src/html.c
16f4f3d19a9ef411ae14664b49d5c02b48e696f2baaf5aa8740357e90c98166e  upstream/src/html.h
89b0c0fb10bba478b0bf71910f1c1a417d60bd8ac2b09134f76a84862a81805e  upstream/src/inlines.c
856a7827a3f7b11360dd861b740c407d1b09a596a0370b1254d8f46b0da80b6b  upstream/src/inlines.h
6b40d13a66a432d26685bc6677881a1e3e23510a82a0b247f7d0f6fa91c347ca  upstream/src/iterator.c
a4add6ee1194027aaea64d9545b00118faa308b78471d5eab3c9b566a919f1fe  upstream/src/iterator.h
2303117852800795764a04c24726388405aa5794c26e1cd3ccbabf6c6f805789  upstream/src/linked_list.c
8d7909cab6a7e893223d20aae69d90a9b7891fbeaea8dcf57e4f0dca08f6a213  upstream/src/map.c
5dbbada38f11efd95bf1da887b87a1e067eaf4e1bcd8df6e7f6fd1642fe46010  upstream/src/map.h
3b17902d88e3d12f0d70855a7cabed836d74bd7df065e6a696f4a3d01b308490  upstream/src/node.c
bb27530fbacf902176f25ad13df63f888bd4f249991583c489fe508a74ac0753  upstream/src/node.h
ebb7107c3a256ba4859f8aefdbaad73c53e592cce7f3f09f5ddfef6739253832  upstream/src/parser.h
daeeefcb721709b5ae87cd0ef0158a1aa82c963e07b4a316d986f05e0b6a6ee9  upstream/src/plugin.c
394a8bb69b298dd8f8bfecc74fbfce226e148a680228a702d978430b12fb003d  upstream/src/plugin.h
a83acb7dde757a3203a6a3cc501fcbddb4aee05a77c24de7a3dc9f3d5d5647d3  upstream/src/references.c
772904488c706bf672c4f671737dd7d2315c67be2213ccbf6bde93dd47aa1930  upstream/src/references.h
d17cb2734ddf21825fdc110e5042ce8ac1498d32e1f670619356ba227b6070cf  upstream/src/registry.c
ec94a72c7e6244cfe1d220d1a6dfe658eee1d8e65bfafc09baefd45ef69f3b35  upstream/src/registry.h
158ae470be43040c20b2268143b59a5406354b3894fd9c666b399683d00e39e0  upstream/src/render.h
7e0d16ca84acf11219bc3a4a5ad4bfd9891ae319ffec60552c67d2f6ecbc3cac  upstream/src/scanners.c
c0cc707d1c3c0daaa78f79fa0ed47c625b25f6e6e9004f09be6d8979472bd630  upstream/src/scanners.h
551cc3710ff2796afc32bf9e4878cc5ff61e12ed8e62464c9530915585962275  upstream/src/syntax_extension.c
f8520fd19b5cddcef0984eb8323bf7b4635fefb632fe5f405674d8c9ab4e379c  upstream/src/syntax_extension.h
8565221e756c1e8dbb545725911704564937956b06b8ff00ec473cd32413a6f3  upstream/src/utf8.c
34aa29b8756685437dd330ba8cbea4df97cce70bac9254bdbde093361dacc291  upstream/src/utf8.h
```
