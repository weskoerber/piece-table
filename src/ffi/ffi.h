#pragma once
#ifndef PIECE_TABLE_H
#define PIECE_TABLE_H

#include <stdlib.h>

struct PieceTable;

int pt_init(struct PieceTable **, const char *, size_t);
void pt_deinit(struct PieceTable *);

int pt_insert(struct PieceTable *, size_t, const char *, size_t);
int pt_delete(struct PieceTable *, size_t);
int pt_render(struct PieceTable *, char *, size_t);

#endif // PIECE_TABLE_H
