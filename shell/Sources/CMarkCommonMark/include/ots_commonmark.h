// The CommonMark dialect's parser: vendored cmark 0.31.2 behind the otscm_
// prefix (plan R1, docs/spec/design/2026-1016-markdown-dialects-and-preview.md).
#ifndef OTS_COMMONMARK_H
#define OTS_COMMONMARK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Node kinds; the numbers match OTSGFM_KIND_* in ots_gfm.h.
enum {
  OTSCM_KIND_OTHER = 0,
  OTSCM_KIND_DOCUMENT = 1,
  OTSCM_KIND_BLOCK_QUOTE = 2,
  OTSCM_KIND_LIST = 3,
  OTSCM_KIND_ITEM = 4,
  OTSCM_KIND_CODE_BLOCK = 5,
  OTSCM_KIND_HTML_BLOCK = 6,
  OTSCM_KIND_PARAGRAPH = 7,
  OTSCM_KIND_HEADING = 8,
  OTSCM_KIND_THEMATIC_BREAK = 9,
  OTSCM_KIND_TABLE = 10,
  OTSCM_KIND_TABLE_ROW = 11,
  OTSCM_KIND_TABLE_CELL = 12,
  OTSCM_KIND_TEXT = 20,
  OTSCM_KIND_SOFTBREAK = 21,
  OTSCM_KIND_LINEBREAK = 22,
  OTSCM_KIND_CODE = 23,
  OTSCM_KIND_HTML_INLINE = 24,
  OTSCM_KIND_EMPH = 25,
  OTSCM_KIND_STRONG = 26,
  OTSCM_KIND_LINK = 27,
  OTSCM_KIND_IMAGE = 28,
  OTSCM_KIND_STRIKETHROUGH = 29,
};

// Reference parts for otscm_reference_part.
enum {
  OTSCM_REFERENCE_LABEL = 0,
  OTSCM_REFERENCE_URL = 1,
  OTSCM_REFERENCE_TITLE = 2,
};

typedef struct otscm_document otscm_document;

// Parses UTF-8 with CMARK_OPT_DEFAULT. NULL on allocation failure, for NULL
// text with a nonzero length, and from 256 MiB.
otscm_document *otscm_parse(const char *text, size_t length);
void otscm_document_free(otscm_document *document);
const void *otscm_document_root(const otscm_document *document);

// Every reference definition the parser collected, in the map's own order
// (latest first), duplicates included. Labels are the normalized map labels.
size_t otscm_reference_count(const otscm_document *document);
// NULL and *length 0 when the part is absent or empty, or the index is out of range.
const char *otscm_reference_part(const otscm_document *document, size_t index,
                                 int part, size_t *length);

// Tree walk. NULL past the last node and for a NULL node.
const void *otscm_node_first_child(const void *node);
const void *otscm_node_next(const void *node);
// One of OTSCM_KIND_*; -1 for a NULL node.
int otscm_node_kind(const void *node);

// Bytes with an explicit length, not NUL-terminated by contract. NULL and
// *length 0 for another kind of node or an empty value.
const char *otscm_node_literal(const void *node, size_t *length); // text, code, html_inline, html_block, code_block
const char *otscm_node_url(const void *node, size_t *length);     // link, image
const char *otscm_node_title(const void *node, size_t *length);   // link, image
const char *otscm_node_fence_info(const void *node, size_t *length); // code_block

int otscm_node_heading_level(const void *node); // 1 to 6; 0 for another kind
int otscm_node_list_ordered(const void *node);  // 1 ordered, 0 bullet; -1 for another kind
int otscm_node_list_start(const void *node);    // -1 for another kind
int otscm_node_list_tight(const void *node);    // 1 or 0; -1 for another kind

// cmark's block source positions as-is: 1-based lines, byte columns; 0 for NULL.
int otscm_node_start_line(const void *node);
int otscm_node_start_column(const void *node);
int otscm_node_end_line(const void *node);
int otscm_node_end_column(const void *node);

#ifdef __cplusplus
}
#endif

#endif
