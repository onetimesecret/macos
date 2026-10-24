// The GitHub Flavored Markdown dialect's parser: vendored cmark-gfm 0.29.0.gfm.13
// behind the otsgfm_ prefix (plan R1, docs/spec/design/2026-1016-markdown-dialects-and-preview.md).
#ifndef OTS_GFM_H
#define OTS_GFM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Node kinds; the numbers match OTSCM_KIND_* in ots_commonmark.h.
enum {
  OTSGFM_KIND_OTHER = 0,
  OTSGFM_KIND_DOCUMENT = 1,
  OTSGFM_KIND_BLOCK_QUOTE = 2,
  OTSGFM_KIND_LIST = 3,
  OTSGFM_KIND_ITEM = 4,
  OTSGFM_KIND_CODE_BLOCK = 5,
  OTSGFM_KIND_HTML_BLOCK = 6,
  OTSGFM_KIND_PARAGRAPH = 7,
  OTSGFM_KIND_HEADING = 8,
  OTSGFM_KIND_THEMATIC_BREAK = 9,
  OTSGFM_KIND_TABLE = 10,
  OTSGFM_KIND_TABLE_ROW = 11,
  OTSGFM_KIND_TABLE_CELL = 12,
  OTSGFM_KIND_TEXT = 20,
  OTSGFM_KIND_SOFTBREAK = 21,
  OTSGFM_KIND_LINEBREAK = 22,
  OTSGFM_KIND_CODE = 23,
  OTSGFM_KIND_HTML_INLINE = 24,
  OTSGFM_KIND_EMPH = 25,
  OTSGFM_KIND_STRONG = 26,
  OTSGFM_KIND_LINK = 27,
  OTSGFM_KIND_IMAGE = 28,
  OTSGFM_KIND_STRIKETHROUGH = 29,
};

// Reference parts for otsgfm_reference_part.
enum {
  OTSGFM_REFERENCE_LABEL = 0,
  OTSGFM_REFERENCE_URL = 1,
  OTSGFM_REFERENCE_TITLE = 2,
};

typedef struct otsgfm_document otsgfm_document;

// Parses UTF-8 with CMARK_OPT_DEFAULT plus table, strikethrough, autolink, tagfilter and tasklist, one
// parse at a time. NULL on allocation failure, for NULL text with a nonzero length, and from 256 MiB.
// Every table of the parse together may take `table_cells` cells, padding included (patches/0003).
otsgfm_document *otsgfm_parse(const char *text, size_t length, int64_t table_cells);
void otsgfm_document_free(otsgfm_document *document);
const void *otsgfm_document_root(const otsgfm_document *document);
// 1 when a table header or row was refused for want of cells, so the tree is not the page's.
int otsgfm_document_table_cells_exhausted(const otsgfm_document *document);

// Every reference definition the parser collected, in the map's own order
// (latest first), duplicates included. Labels are the normalized map labels.
size_t otsgfm_reference_count(const otsgfm_document *document);
// NULL and *length 0 when the part is absent or empty, or the index is out of range.
const char *otsgfm_reference_part(const otsgfm_document *document, size_t index,
                                  int part, size_t *length);

// Tree walk. NULL past the last node and for a NULL node.
const void *otsgfm_node_first_child(const void *node);
const void *otsgfm_node_next(const void *node);
// One of OTSGFM_KIND_*; -1 for a NULL node.
int otsgfm_node_kind(const void *node);

// Bytes with an explicit length, not NUL-terminated by contract. NULL and
// *length 0 for another kind of node or an empty value.
const char *otsgfm_node_literal(const void *node, size_t *length); // text, code, html_inline, html_block, code_block
const char *otsgfm_node_url(const void *node, size_t *length);     // link, image
const char *otsgfm_node_title(const void *node, size_t *length);   // link, image
const char *otsgfm_node_fence_info(const void *node, size_t *length); // code_block

int otsgfm_node_heading_level(const void *node); // 1 to 6; 0 for another kind
int otsgfm_node_list_ordered(const void *node);  // 1 ordered, 0 bullet; -1 for another kind
int otsgfm_node_list_start(const void *node);    // -1 for another kind
int otsgfm_node_list_tight(const void *node);    // 1 or 0; -1 for another kind

// cmark-gfm's block source positions as-is: 1-based lines, byte columns; 0 for NULL.
int otsgfm_node_start_line(const void *node);
int otsgfm_node_start_column(const void *node);
int otsgfm_node_end_line(const void *node);
int otsgfm_node_end_column(const void *node);

int otsgfm_node_task_state(const void *item);   // -1 not a task item, 0 unchecked, 1 checked
int otsgfm_table_column_count(const void *table); // 0 for another kind
// 0 none, 1 left, 2 center, 3 right; -1 for another kind or a column out of range.
int otsgfm_table_alignment(const void *table, int column);
int otsgfm_table_row_is_header(const void *row); // 1 or 0; -1 for another kind

#ifdef __cplusplus
}
#endif

#endif
