#ifndef CMARK_GFM_TABLE_H
#define CMARK_GFM_TABLE_H

#include "cmark-gfm-core-extensions.h"


extern cmark_node_type CMARK_NODE_TABLE, CMARK_NODE_TABLE_ROW,
    CMARK_NODE_TABLE_CELL;

cmark_syntax_extension *create_table_extension(void);

#include <stdbool.h>
#include <stdint.h>

// Onetime Pad: every table of one parse shares one cell budget. The budget is
// process wide, so set and read it under the caller's parse lock.
void ots_table_set_cell_budget(int64_t cells);
bool ots_table_cell_budget_exhausted(void);

#endif
