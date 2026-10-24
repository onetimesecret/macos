#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef LAB_GFM
#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"
#include "cmark-gfm-extension_api.h"
#include "registry.h"
extern int cmark_utf8proc_is_punctuation(int32_t uc);
#define lab_is_punctuation cmark_utf8proc_is_punctuation
#else
#include "cmark.h"
extern int cmark_utf8proc_is_punctuation_or_symbol(int32_t uc);
#define lab_is_punctuation cmark_utf8proc_is_punctuation_or_symbol
#endif

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  if (!strcmp(argv[1], "--version")) {
    puts(cmark_version_string());
    return 0;
  }
  if (!strcmp(argv[1], "--classify")) {
    printf("{\"A\":%d,\"U+FFFC\":%d}\n",
           lab_is_punctuation('A'),
           lab_is_punctuation(0xFFFC));
    return 0;
  }
  int html = !strcmp(argv[1], "--html") || !strcmp(argv[1], "--html-core");
  if (!html && strcmp(argv[1], "--xml")) return 2;
  int options = CMARK_OPT_DEFAULT | CMARK_OPT_UNSAFE;
  cmark_parser *parser = cmark_parser_new(options);
  if (!parser) return 3;
#ifdef LAB_GFM
  cmark_gfm_core_extensions_ensure_registered();
  const char *extensions[] = {"table", "strikethrough", "autolink", "tagfilter", "tasklist"};
  for (size_t i = 0; strcmp(argv[1], "--html-core") &&
       i < sizeof(extensions) / sizeof(extensions[0]); ++i) {
    cmark_syntax_extension *extension = cmark_find_syntax_extension(extensions[i]);
    if (!extension || !cmark_parser_attach_syntax_extension(parser, extension)) return 4;
  }
#endif
  char buffer[8192];
  size_t length;
  while ((length = fread(buffer, 1, sizeof(buffer), stdin)))
    cmark_parser_feed(parser, buffer, length);
  if (ferror(stdin)) return 5;
  cmark_node *document = cmark_parser_finish(parser);
  char *rendered;
  if (html) {
#ifdef LAB_GFM
    rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser));
#else
    rendered = cmark_render_html(document, options);
#endif
  } else {
    rendered = cmark_render_xml(document, CMARK_OPT_SOURCEPOS);
  }
  if (!rendered) return 6;
  fputs(rendered, stdout);
  free(rendered);
  cmark_node_free(document);
  cmark_parser_free(parser);
#ifdef LAB_GFM
  cmark_release_plugins();
#endif
  return 0;
}
