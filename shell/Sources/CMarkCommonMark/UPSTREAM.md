# cmark 0.31.2, vendored

Written by `scripts/vendor-cmark.sh`; `scripts/vendor-cmark.sh --check` verifies
this file, `upstream/` and `prefix.h` offline. Do not edit by hand.

- Repository: https://github.com/commonmark/cmark
- Tag: 0.31.2
- Commit: eec0eeba6d31189fd828314576494566d539b1e3
- Patches: none

## Kept files

`upstream/` has `COPYING` and the files from upstream `src/` that the SHA-256
list below names, copied byte-identical.

The shim parses and walks the tree, which needs the block and inline parsers,
the node, buffer, UTF-8, entity and reference code and the pregenerated
`scanners.c` (re2c is not needed). `cmark.c` defines the default allocator
and also `cmark_markdown_to_html`, which calls `cmark_render_html`, so
`html.c` and the two escapers it calls (`houdini_html_e.c`,
`houdini_href_e.c`) stay and the target links with no undefined symbol.
Left out: `main.c` (the command line tool) and the other renderers
(`commonmark.c`, `latex.c`, `man.c`, `xml.c`, `render.c`), which no kept
file calls.

`generated/` stands in for what CMake writes (`cmark_export.h`,
`cmark_version.h`). `prefix.h` defines every external symbol of a build of
`upstream/` to `otscm_<name>`, and the target force-includes it into
every C file.

## SHA-256

```
c22e885f33b821bddb24cf007145e5540655b6c0f403e49e6c76a93c28e6d9a9  upstream/COPYING
49cf77005874a516a30b5ab7ef22334e737c7e21cbe7e1b543451587afd0633a  upstream/blocks.c
81b022cb387d68b9a5f520a01137c0ba9a66156e1f4c9819523e15e0853f21a3  upstream/buffer.c
c77966c4c44ea8c8a408a06427334880de23015705ac41b7a40814c61f3933f0  upstream/buffer.h
bb9d244eb07065876c5f1d3d97f8c1afd6d02470e195c8274c6348f9ea968c4b  upstream/case_fold.inc
0e1cddb27e76357efbe7b6df4e5d9b413f03895067ea3f56bb3e48ffba44af29  upstream/chunk.h
339c5a4d83eece335d54e2a4d7096394c8206392638e9fae681fac6766f989e0  upstream/cmark.c
9fb5823207fa7dfd66953dd5c3b82e73ef47df697f706abe0c482ef255f9581f  upstream/cmark.h
5421684fd63be733541ec328db01867f1392256fb01da1a05d5e54fdeaa364ce  upstream/cmark_ctype.c
334a90d4be425c9a4c0974a395ba46b5160ebcd861524661aa063e24cdab0d92  upstream/cmark_ctype.h
88361c6d559915b3f3ecd77bb5d7e20cf37612fc831ba576c85ed24188a0b283  upstream/entities.inc
ef34157c1a4dd25b066ee6812bb31cdda1d985123050d0c91819ab8cf5134e8c  upstream/houdini.h
1004092b1c6a890540ee1bc8724fb46316fddaea409be7ffa8d2e4f4977e9b22  upstream/houdini_href_e.c
82979941823f6d2ba63af4ebc91ece8de31c6e640452318a7f762ac72e22e982  upstream/houdini_html_e.c
184a3c3e7885335a1cb484ef370b17f6170574bc1fffc84a5a9fca92b49fa486  upstream/houdini_html_u.c
5ea4867fc61ae562fe5ff1b8e91971d5c7dd671a1c9e25b0b1200212f3f3a0a1  upstream/html.c
2383a329fdf676f92514491c9ba80a7ebc8fe02ee95e87a6b76d7283b6eddb1c  upstream/inlines.c
fbb506271dcee4d56d3aa421360654f36fc75d27f067c87221e035bb42f80d28  upstream/inlines.h
b3a34276cad34252dcb478ed4c7da80c54074221b3538cb111f07c635def05bf  upstream/iterator.c
0a65f9dbb93e4eaa04471c0f1f70e9106504946d4553c8dfdec2204b15b2ab9a  upstream/iterator.h
1b36e14afb62082b64021477dc3a8142bc7c29b9e77ff53d9854d6c73fc11db2  upstream/node.c
420f19cc8779d976fb7b4478a38281f3db437df0434c3c20a02e7e6463fb6afb  upstream/node.h
dfc96cce951a4818b0705b79b83fee5af2511bb0a1f63c3eb3a0583ec84ce588  upstream/parser.h
2d65cf8881053291e6013dbacbb3d81fff57033e4ee97205f054e4c9741d77ee  upstream/references.c
7188bcb721ea62aa17acacf5df5c9d4a5d5d93378ad6fbb87b8d254b7e6e4518  upstream/references.h
58b280ab162c59242e80ec920d08635544c9205fe9370a54a2dc3f5f83afc37a  upstream/scanners.c
4f7bc9b93b147714c0eab66fce534a8355ff9d396aa4b4dd30adc6ac2ee24556  upstream/scanners.h
882f8364abef18c18834d79d8693c3152bb65962d49bf988c50718971775d775  upstream/utf8.c
52733725b5aaa1b2f0bb83ce8e08d7d9aef2d8e95909445e962c257a833e1461  upstream/utf8.h
```
