// The otscm_ API over vendored cmark 0.31.2 (plan R1). The private headers
// give the reference map and explicit literal lengths the public API lacks.
#include "ots_commonmark.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "cmark.h"
#include "node.h"
#include "parser.h"
#include "references.h"

// cmark aborts once a buffer passes INT32_MAX / 2 bytes, and a NUL input byte
// becomes three (U+FFFD), so input stops short of that at 256 MiB.
#define INPUT_LIMIT ((size_t)INT32_MAX / 8)

typedef struct {
  const char *bytes;
  size_t length;
} span;

struct otscm_document {
  cmark_parser *parser; // owns the reference map the spans below point into
  cmark_node *root;
  size_t reference_count;
  span (*references)[3];
};

static const char *give(const span part, size_t *length) {
  if (length == NULL)
    return NULL;
  *length = part.bytes != NULL ? part.length : 0;
  return *length > 0 ? part.bytes : NULL;
}

static span cstring(const unsigned char *bytes) {
  span part = {(const char *)bytes, bytes != NULL ? strlen((const char *)bytes) : 0};
  return part;
}

// The refmap lives until cmark_parser_free, so the snapshot points into it.
static int snapshot_references(otscm_document *document) {
  const cmark_reference_map *map = document->parser->refmap;
  size_t count = 0;
  for (const cmark_reference *ref = map != NULL ? map->refs : NULL; ref != NULL; ref = ref->next)
    count++;
  if (count == 0)
    return 1;
  document->references = calloc(count, sizeof *document->references);
  if (document->references == NULL)
    return 0;
  size_t index = 0;
  for (const cmark_reference *ref = map->refs; ref != NULL; ref = ref->next, index++) {
    document->references[index][OTSCM_REFERENCE_LABEL] = cstring(ref->label);
    document->references[index][OTSCM_REFERENCE_URL] = cstring(ref->url);
    document->references[index][OTSCM_REFERENCE_TITLE] = cstring(ref->title);
  }
  document->reference_count = count;
  return 1;
}

otscm_document *otscm_parse(const char *text, size_t length) {
  if ((text == NULL && length > 0) || length > INPUT_LIMIT)
    return NULL;
  otscm_document *document = calloc(1, sizeof *document);
  if (document == NULL)
    return NULL;
  document->parser = cmark_parser_new(CMARK_OPT_DEFAULT);
  if (document->parser == NULL) {
    free(document);
    return NULL;
  }
  cmark_parser_feed(document->parser, text != NULL ? text : "", length);
  document->root = cmark_parser_finish(document->parser);
  if (document->root == NULL || !snapshot_references(document)) {
    otscm_document_free(document);
    return NULL;
  }
  return document;
}

void otscm_document_free(otscm_document *document) {
  if (document == NULL)
    return;
  if (document->root != NULL)
    cmark_node_free(document->root);
  if (document->parser != NULL)
    cmark_parser_free(document->parser);
  free(document->references);
  free(document);
}

const void *otscm_document_root(const otscm_document *document) {
  return document != NULL ? document->root : NULL;
}

size_t otscm_reference_count(const otscm_document *document) {
  return document != NULL ? document->reference_count : 0;
}

const char *otscm_reference_part(const otscm_document *document, size_t index,
                                 int part, size_t *length) {
  if (length != NULL)
    *length = 0;
  if (document == NULL || index >= document->reference_count || part < 0 || part > 2)
    return NULL;
  return give(document->references[index][part], length);
}

const void *otscm_node_first_child(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->first_child : NULL;
}

const void *otscm_node_next(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->next : NULL;
}

int otscm_node_kind(const void *node) {
  if (node == NULL)
    return -1;
  switch (((const cmark_node *)node)->type) {
  case CMARK_NODE_DOCUMENT: return OTSCM_KIND_DOCUMENT;
  case CMARK_NODE_BLOCK_QUOTE: return OTSCM_KIND_BLOCK_QUOTE;
  case CMARK_NODE_LIST: return OTSCM_KIND_LIST;
  case CMARK_NODE_ITEM: return OTSCM_KIND_ITEM;
  case CMARK_NODE_CODE_BLOCK: return OTSCM_KIND_CODE_BLOCK;
  case CMARK_NODE_HTML_BLOCK: return OTSCM_KIND_HTML_BLOCK;
  case CMARK_NODE_PARAGRAPH: return OTSCM_KIND_PARAGRAPH;
  case CMARK_NODE_HEADING: return OTSCM_KIND_HEADING;
  case CMARK_NODE_THEMATIC_BREAK: return OTSCM_KIND_THEMATIC_BREAK;
  case CMARK_NODE_TEXT: return OTSCM_KIND_TEXT;
  case CMARK_NODE_SOFTBREAK: return OTSCM_KIND_SOFTBREAK;
  case CMARK_NODE_LINEBREAK: return OTSCM_KIND_LINEBREAK;
  case CMARK_NODE_CODE: return OTSCM_KIND_CODE;
  case CMARK_NODE_HTML_INLINE: return OTSCM_KIND_HTML_INLINE;
  case CMARK_NODE_EMPH: return OTSCM_KIND_EMPH;
  case CMARK_NODE_STRONG: return OTSCM_KIND_STRONG;
  case CMARK_NODE_LINK: return OTSCM_KIND_LINK;
  case CMARK_NODE_IMAGE: return OTSCM_KIND_IMAGE;
  default: return OTSCM_KIND_OTHER;
  }
}

const char *otscm_node_literal(const void *node, size_t *length) {
  if (length != NULL)
    *length = 0;
  if (node == NULL)
    return NULL;
  const cmark_node *n = node;
  switch (n->type) {
  case CMARK_NODE_TEXT:
  case CMARK_NODE_CODE:
  case CMARK_NODE_HTML_INLINE:
  case CMARK_NODE_HTML_BLOCK:
  case CMARK_NODE_CODE_BLOCK: {
    span part = {(const char *)n->data, n->len > 0 ? (size_t)n->len : 0};
    return give(part, length);
  }
  default:
    return NULL;
  }
}

static int is_link(const cmark_node *n) {
  return n != NULL && (n->type == CMARK_NODE_LINK || n->type == CMARK_NODE_IMAGE);
}

const char *otscm_node_url(const void *node, size_t *length) {
  if (length != NULL)
    *length = 0;
  return is_link(node) ? give(cstring(((const cmark_node *)node)->as.link.url), length) : NULL;
}

const char *otscm_node_title(const void *node, size_t *length) {
  if (length != NULL)
    *length = 0;
  return is_link(node) ? give(cstring(((const cmark_node *)node)->as.link.title), length) : NULL;
}

const char *otscm_node_fence_info(const void *node, size_t *length) {
  if (length != NULL)
    *length = 0;
  const cmark_node *n = node;
  if (n == NULL || n->type != CMARK_NODE_CODE_BLOCK)
    return NULL;
  return give(cstring(n->as.code.info), length);
}

int otscm_node_heading_level(const void *node) {
  const cmark_node *n = node;
  return n != NULL && n->type == CMARK_NODE_HEADING ? n->as.heading.level : 0;
}

int otscm_node_list_ordered(const void *node) {
  const cmark_node *n = node;
  if (n == NULL || n->type != CMARK_NODE_LIST)
    return -1;
  return n->as.list.list_type == CMARK_ORDERED_LIST ? 1 : 0;
}

int otscm_node_list_start(const void *node) {
  const cmark_node *n = node;
  return n != NULL && n->type == CMARK_NODE_LIST ? n->as.list.start : -1;
}

int otscm_node_list_tight(const void *node) {
  const cmark_node *n = node;
  if (n == NULL || n->type != CMARK_NODE_LIST)
    return -1;
  return n->as.list.tight ? 1 : 0;
}

int otscm_node_start_line(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->start_line : 0;
}

int otscm_node_start_column(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->start_column : 0;
}

int otscm_node_end_line(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->end_line : 0;
}

int otscm_node_end_column(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->end_column : 0;
}
