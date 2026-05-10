#include <stdio.h>

#include <piece_table/piece_table.h>

int main(void) {
  struct PieceTable *t;
  pt_init(&t, "world!", 6);
  pt_insert(t, 0, "Hello ", 6);

  char buf[16] = {0};
  pt_render(t, buf, 16);

  printf("%s\n", buf);
}
