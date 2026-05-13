#include <stdio.h>

#include <piece_table/piece_table.h>

int main(void) {
  struct PieceTable *t;
  pt_init(&t, "world", 5);
  pt_insert(t, 0, "Hello ", 6);
  pt_append(t, "!", 1);

  size_t length = pt_length(t);

  char *buf = (char *)malloc(length + 1);
  buf[length] = 0;

  pt_render(t, buf, 16);

  printf("%s (%d)\n", buf, length);
}
