// The otsgfm_ API over vendored cmark-gfm 0.29.0.gfm.13 (plan R1). The private
// headers give the reference map and the extension node types.
#include "ots_gfm.h"

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"
#include "node.h"
#include "parser.h"
#include "references.h"
#include "strikethrough.h"
#include "syntax_extension.h"
#include "table.h"

// cmark aborts once a buffer passes INT32_MAX / 2 bytes, and a NUL input byte
// becomes three (U+FFFD), so input stops short of that at 256 MiB.
#define INPUT_LIMIT ((size_t)INT32_MAX / 8)

enum { TASKLIST = 4, EXTENSION_COUNT = 5 };
static const char *const extension_names[EXTENSION_COUNT] = {
    "table", "strikethrough", "autolink", "tagfilter", [TASKLIST] = "tasklist"};
static cmark_syntax_extension *extensions[EXTENSION_COUNT];
static pthread_once_t registration = PTHREAD_ONCE_INIT;

// Each inline parse toggles inlines.c's process-wide SPECIAL_CHARS table.
static pthread_mutex_t parse_lock = PTHREAD_MUTEX_INITIALIZER;

static void register_extensions(void) {
  cmark_gfm_core_extensions_ensure_registered();
  for (int i = 0; i < EXTENSION_COUNT; i++)
    extensions[i] = cmark_find_syntax_extension(extension_names[i]);
}

typedef struct {
  const char *bytes;
  size_t length;
} span;

struct otsgfm_document {
  cmark_parser *parser;
  cmark_syntax_extension *capture; // copies the reference map before finish resets it
  cmark_node *root;
  int capture_failed;
  size_t reference_count;
  span (*references)[3];
  char *reference_bytes;
};

static const char *give(const span part, size_t *length) {
  if (length == NULL)
    return NULL;
  *length = part.bytes != NULL ? part.length : 0;
  return *length > 0 ? part.bytes : NULL;
}

static span chunk_span(const cmark_chunk *chunk) {
  span part = {(const char *)chunk->data, chunk->len > 0 ? (size_t)chunk->len : 0};
  return part;
}

static void entry_parts(const cmark_map_entry *entry, span parts[3]) {
  const cmark_reference *ref = (const cmark_reference *)entry;
  parts[OTSGFM_REFERENCE_LABEL].bytes = (const char *)entry->label;
  parts[OTSGFM_REFERENCE_LABEL].length =
      entry->label != NULL ? strlen((const char *)entry->label) : 0;
  parts[OTSGFM_REFERENCE_URL] = chunk_span(&ref->url);
  parts[OTSGFM_REFERENCE_TITLE] = chunk_span(&ref->title);
}

// cmark_parser_finish frees the reference map, so its parts are copied here, in
// the postprocess pass that runs after the last definition and before the reset.
static cmark_node *capture_references(cmark_syntax_extension *extension,
                                      cmark_parser *parser, cmark_node *root) {
  (void)root;
  otsgfm_document *document = cmark_syntax_extension_get_private(extension);
  const cmark_map_entry *first = parser->refmap != NULL ? parser->refmap->refs : NULL;
  size_t count = 0, bytes = 0;
  span parts[3];
  for (const cmark_map_entry *entry = first; entry != NULL; entry = entry->next, count++) {
    entry_parts(entry, parts);
    bytes += parts[0].length + parts[1].length + parts[2].length;
  }
  if (count == 0)
    return NULL;
  document->references = calloc(count, sizeof *document->references);
  document->reference_bytes = malloc(bytes > 0 ? bytes : 1);
  if (document->references == NULL || document->reference_bytes == NULL) {
    document->capture_failed = 1;
    return NULL;
  }
  char *cursor = document->reference_bytes;
  size_t index = 0;
  for (const cmark_map_entry *entry = first; entry != NULL; entry = entry->next, index++) {
    entry_parts(entry, parts);
    for (int part = 0; part < 3; part++) {
      if (parts[part].bytes == NULL || parts[part].length == 0)
        continue;
      memcpy(cursor, parts[part].bytes, parts[part].length);
      document->references[index][part].bytes = cursor;
      document->references[index][part].length = parts[part].length;
      cursor += parts[part].length;
    }
  }
  document->reference_count = count;
  return NULL;
}

otsgfm_document *otsgfm_parse(const char *text, size_t length) {
  if ((text == NULL && length > 0) || length > INPUT_LIMIT)
    return NULL;
  if (pthread_once(&registration, register_extensions) != 0)
    return NULL;
  for (int i = 0; i < EXTENSION_COUNT; i++)
    if (extensions[i] == NULL)
      return NULL;
  otsgfm_document *document = calloc(1, sizeof *document);
  if (document == NULL)
    return NULL;
  document->capture = cmark_syntax_extension_new("ots-references");
  document->parser = cmark_parser_new(CMARK_OPT_DEFAULT);
  if (document->capture == NULL || document->parser == NULL) {
    otsgfm_document_free(document);
    return NULL;
  }
  cmark_syntax_extension_set_postprocess_func(document->capture, capture_references);
  cmark_syntax_extension_set_private(document->capture, document, NULL);
  for (int i = 0; i < EXTENSION_COUNT; i++)
    cmark_parser_attach_syntax_extension(document->parser, extensions[i]);
  cmark_parser_attach_syntax_extension(document->parser, document->capture);

  pthread_mutex_lock(&parse_lock);
  cmark_parser_feed(document->parser, text != NULL ? text : "", length);
  document->root = cmark_parser_finish(document->parser);
  pthread_mutex_unlock(&parse_lock);

  if (document->root == NULL || document->capture_failed) {
    otsgfm_document_free(document);
    return NULL;
  }
  return document;
}

void otsgfm_document_free(otsgfm_document *document) {
  if (document == NULL)
    return;
  if (document->root != NULL)
    cmark_node_free(document->root);
  if (document->parser != NULL)
    cmark_parser_free(document->parser);
  if (document->capture != NULL)
    cmark_syntax_extension_free(cmark_get_default_mem_allocator(), document->capture);
  free(document->references);
  free(document->reference_bytes);
  free(document);
}

const void *otsgfm_document_root(const otsgfm_document *document) {
  return document != NULL ? document->root : NULL;
}

size_t otsgfm_reference_count(const otsgfm_document *document) {
  return document != NULL ? document->reference_count : 0;
}

const char *otsgfm_reference_part(const otsgfm_document *document, size_t index,
                                  int part, size_t *length) {
  if (length != NULL)
    *length = 0;
  if (document == NULL || index >= document->reference_count || part < 0 || part > 2)
    return NULL;
  return give(document->references[index][part], length);
}

const void *otsgfm_node_first_child(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->first_child : NULL;
}

const void *otsgfm_node_next(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->next : NULL;
}

int otsgfm_node_kind(const void *node) {
  if (node == NULL)
    return -1;
  const uint16_t type = ((const cmark_node *)node)->type;
  switch (type) {
  case CMARK_NODE_DOCUMENT: return OTSGFM_KIND_DOCUMENT;
  case CMARK_NODE_BLOCK_QUOTE: return OTSGFM_KIND_BLOCK_QUOTE;
  case CMARK_NODE_LIST: return OTSGFM_KIND_LIST;
  case CMARK_NODE_ITEM: return OTSGFM_KIND_ITEM;
  case CMARK_NODE_CODE_BLOCK: return OTSGFM_KIND_CODE_BLOCK;
  case CMARK_NODE_HTML_BLOCK: return OTSGFM_KIND_HTML_BLOCK;
  case CMARK_NODE_PARAGRAPH: return OTSGFM_KIND_PARAGRAPH;
  case CMARK_NODE_HEADING: return OTSGFM_KIND_HEADING;
  case CMARK_NODE_THEMATIC_BREAK: return OTSGFM_KIND_THEMATIC_BREAK;
  case CMARK_NODE_TEXT: return OTSGFM_KIND_TEXT;
  case CMARK_NODE_SOFTBREAK: return OTSGFM_KIND_SOFTBREAK;
  case CMARK_NODE_LINEBREAK: return OTSGFM_KIND_LINEBREAK;
  case CMARK_NODE_CODE: return OTSGFM_KIND_CODE;
  case CMARK_NODE_HTML_INLINE: return OTSGFM_KIND_HTML_INLINE;
  case CMARK_NODE_EMPH: return OTSGFM_KIND_EMPH;
  case CMARK_NODE_STRONG: return OTSGFM_KIND_STRONG;
  case CMARK_NODE_LINK: return OTSGFM_KIND_LINK;
  case CMARK_NODE_IMAGE: return OTSGFM_KIND_IMAGE;
  default: break;
  }
  // The extension types are numbered at registration, so they are variables.
  if (type == CMARK_NODE_TABLE)
    return OTSGFM_KIND_TABLE;
  if (type == CMARK_NODE_TABLE_ROW)
    return OTSGFM_KIND_TABLE_ROW;
  if (type == CMARK_NODE_TABLE_CELL)
    return OTSGFM_KIND_TABLE_CELL;
  if (type == CMARK_NODE_STRIKETHROUGH)
    return OTSGFM_KIND_STRIKETHROUGH;
  return OTSGFM_KIND_OTHER;
}

const char *otsgfm_node_literal(const void *node, size_t *length) {
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
    return give(chunk_span(&n->as.literal), length);
  case CMARK_NODE_CODE_BLOCK:
    return give(chunk_span(&n->as.code.literal), length);
  default:
    return NULL;
  }
}

static int is_link(const cmark_node *n) {
  return n != NULL && (n->type == CMARK_NODE_LINK || n->type == CMARK_NODE_IMAGE);
}

const char *otsgfm_node_url(const void *node, size_t *length) {
  if (length != NULL)
    *length = 0;
  return is_link(node) ? give(chunk_span(&((const cmark_node *)node)->as.link.url), length) : NULL;
}

const char *otsgfm_node_title(const void *node, size_t *length) {
  if (length != NULL)
    *length = 0;
  return is_link(node) ? give(chunk_span(&((const cmark_node *)node)->as.link.title), length) : NULL;
}

const char *otsgfm_node_fence_info(const void *node, size_t *length) {
  if (length != NULL)
    *length = 0;
  const cmark_node *n = node;
  if (n == NULL || n->type != CMARK_NODE_CODE_BLOCK)
    return NULL;
  return give(chunk_span(&n->as.code.info), length);
}

int otsgfm_node_heading_level(const void *node) {
  const cmark_node *n = node;
  return n != NULL && n->type == CMARK_NODE_HEADING ? n->as.heading.level : 0;
}

int otsgfm_node_list_ordered(const void *node) {
  const cmark_node *n = node;
  if (n == NULL || n->type != CMARK_NODE_LIST)
    return -1;
  return n->as.list.list_type == CMARK_ORDERED_LIST ? 1 : 0;
}

int otsgfm_node_list_start(const void *node) {
  const cmark_node *n = node;
  return n != NULL && n->type == CMARK_NODE_LIST ? n->as.list.start : -1;
}

int otsgfm_node_list_tight(const void *node) {
  const cmark_node *n = node;
  if (n == NULL || n->type != CMARK_NODE_LIST)
    return -1;
  return n->as.list.tight ? 1 : 0;
}

int otsgfm_node_start_line(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->start_line : 0;
}

int otsgfm_node_start_column(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->start_column : 0;
}

int otsgfm_node_end_line(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->end_line : 0;
}

int otsgfm_node_end_column(const void *node) {
  return node != NULL ? ((const cmark_node *)node)->end_column : 0;
}

// The tasklist extension marks a task item by taking the item over.
int otsgfm_node_task_state(const void *item) {
  const cmark_node *n = item;
  if (n == NULL || n->type != CMARK_NODE_ITEM || n->extension == NULL ||
      n->extension != extensions[TASKLIST])
    return -1;
  return n->as.list.checked ? 1 : 0;
}

int otsgfm_table_column_count(const void *table) {
  const cmark_node *n = table;
  if (n == NULL || n->type != CMARK_NODE_TABLE)
    return 0;
  return cmark_gfm_extensions_get_table_columns((cmark_node *)n);
}

int otsgfm_table_alignment(const void *table, int column) {
  const cmark_node *n = table;
  if (n == NULL || n->type != CMARK_NODE_TABLE || column < 0 ||
      column >= otsgfm_table_column_count(n))
    return -1;
  const uint8_t *alignments = cmark_gfm_extensions_get_table_alignments((cmark_node *)n);
  if (alignments == NULL)
    return 0;
  switch (alignments[column]) {
  case 'l': return 1;
  case 'c': return 2;
  case 'r': return 3;
  default: return 0;
  }
}

int otsgfm_table_row_is_header(const void *row) {
  const cmark_node *n = row;
  if (n == NULL || n->type != CMARK_NODE_TABLE_ROW)
    return -1;
  return cmark_gfm_extensions_get_table_row_is_header((cmark_node *)n) ? 1 : 0;
}
