#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef LAB_GFM
#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"
#include "cmark-gfm-extension_api.h"
#include "registry.h"
#define LAB_COMPILED_VERSION CMARK_GFM_VERSION_STRING
#else
#include "cmark.h"
#define LAB_COMPILED_VERSION CMARK_VERSION_STRING
#endif

static void json_string(const char *value) {
  const unsigned char *s = (const unsigned char *)(value ? value : "");
  putchar('"');
  for (; *s; ++s) {
    if (*s == '"' || *s == '\\') {
      putchar('\\');
      putchar(*s);
    } else if (*s < 32) {
      printf("\\u%04x", *s);
    } else {
      putchar(*s);
    }
  }
  putchar('"');
}

static void json_node(cmark_node *node) {
  const char *type = cmark_node_get_type_string(node);
  fputs("{\"type\":", stdout);
  json_string(type);
  const char *literal = cmark_node_get_literal(node);
  if (literal) {
    fputs(",\"literal\":", stdout);
    json_string(literal);
  }
  if (!strcmp(type, "link") || !strcmp(type, "image")) {
    fputs(",\"properties\":{\"destination\":", stdout);
    json_string(cmark_node_get_url(node));
    fputs(",\"title\":", stdout);
    json_string(cmark_node_get_title(node));
    putchar('}');
  }
#ifdef LAB_SWIFT
  if (!strcmp(type, "attribute")) {
    fputs(",\"properties\":{\"attributes\":", stdout);
    json_string(cmark_node_get_attributes(node));
    putchar('}');
  }
  if (!strcmp(type, "table_cell")) {
    printf(",\"properties\":{\"colspan\":%u,\"rowspan\":%u}",
           cmark_gfm_extensions_get_table_cell_colspan(node),
           cmark_gfm_extensions_get_table_cell_rowspan(node));
  }
#endif
  cmark_node *child = cmark_node_first_child(node);
  if (child) {
    fputs(",\"children\":[", stdout);
    for (int first = 1; child; child = cmark_node_next(child)) {
      if (!first) putchar(',');
      first = 0;
      json_node(child);
    }
    putchar(']');
  }
  putchar('}');
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  const char *profile = argv[1];
  int parse_options = 0;
  int extension_set = 0;
  if (!strcmp(profile, "core")) {
  } else if (!strcmp(profile, "smart")) {
    parse_options = CMARK_OPT_SMART;
#ifdef LAB_GFM
  } else if (!strcmp(profile, "gfm") || !strcmp(profile, "gfm-double")) {
    extension_set = 1;
    if (!strcmp(profile, "gfm-double")) parse_options |= CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE;
#ifdef LAB_SWIFT
  } else if (!strcmp(profile, "gfm-spans")) {
    extension_set = 1;
    parse_options = CMARK_OPT_TABLE_SPANS;
  } else if (!strcmp(profile, "preview") || !strcmp(profile, "preview-spans-off") ||
             !strcmp(profile, "wrapper-default") || !strcmp(profile, "preview-double") ||
             !strcmp(profile, "preview-no-sourcepos")) {
    extension_set = 2;
    parse_options = CMARK_OPT_TABLE_SPANS | CMARK_OPT_SOURCEPOS;
    if (!strcmp(profile, "preview-spans-off")) parse_options &= ~CMARK_OPT_TABLE_SPANS;
    if (!strcmp(profile, "wrapper-default")) parse_options |= CMARK_OPT_SMART;
    if (!strcmp(profile, "preview-double")) parse_options |= CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE;
    if (!strcmp(profile, "preview-no-sourcepos")) parse_options &= ~CMARK_OPT_SOURCEPOS;
#endif
#endif
  } else {
    return 2;
  }
  const char *gfm_extensions[] = {"table", "strikethrough", "autolink", "tagfilter", "tasklist"};
  const char *wrapper_extensions[] = {"table", "strikethrough", "tasklist"};
  const char **names = extension_set == 1 ? gfm_extensions : wrapper_extensions;
  size_t count = extension_set == 1 ? 5 : extension_set == 2 ? 3 : 0;
  if (!strcmp(argv[2], "--meta")) {
    fputs("{\"version\":", stdout);
    json_string(cmark_version_string());
    fputs(",\"compiled_version\":", stdout);
    json_string(LAB_COMPILED_VERSION);
    printf(",\"parse_options\":%d,\"html_render_options\":%d,\"xml_render_options\":%d,\"extensions\":[",
           parse_options, CMARK_OPT_UNSAFE, CMARK_OPT_SOURCEPOS);
    for (size_t i = 0; i < count; ++i) {
      if (i) putchar(',');
      json_string(names[i]);
    }
    puts("]}");
    return 0;
  }
  if (strcmp(argv[2], "--json") && strcmp(argv[2], "--xml") && strcmp(argv[2], "--html")) return 2;
  cmark_parser *parser = cmark_parser_new(parse_options);
  if (!parser) return 3;
#ifdef LAB_GFM
  cmark_gfm_core_extensions_ensure_registered();
  for (size_t i = 0; i < count; ++i) {
    cmark_syntax_extension *extension = cmark_find_syntax_extension(names[i]);
    if (!extension || !cmark_parser_attach_syntax_extension(parser, extension)) return 4;
  }
#endif
  char input[8192];
  size_t size;
  while ((size = fread(input, 1, sizeof(input), stdin))) cmark_parser_feed(parser, input, size);
  if (ferror(stdin)) return 5;
  cmark_node *document = cmark_parser_finish(parser);
  if (!strcmp(argv[2], "--json")) {
    json_node(document);
    putchar('\n');
  } else {
    char *rendered;
    if (!strcmp(argv[2], "--xml")) {
      rendered = cmark_render_xml(document, CMARK_OPT_SOURCEPOS);
    } else {
#ifdef LAB_GFM
      rendered = cmark_render_html(document, CMARK_OPT_UNSAFE, cmark_parser_get_syntax_extensions(parser));
#else
      rendered = cmark_render_html(document, CMARK_OPT_UNSAFE);
#endif
    }
    if (!rendered) return 6;
    fputs(rendered, stdout);
    free(rendered);
  }
  cmark_node_free(document);
  cmark_parser_free(parser);
#ifdef LAB_GFM
  cmark_release_plugins();
#endif
  return ferror(stdout) ? 7 : 0;
}
