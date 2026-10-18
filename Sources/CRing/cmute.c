#include "cmute.h"
#include <stdatomic.h>
#include <stdlib.h>

#define CMUTE_CAP 256

struct CMuteQueue {
  CMuteEvent items[CMUTE_CAP];
  _Atomic uint64_t head; // pushed
  _Atomic uint64_t tail; // popped
};

CMuteQueue *cmute_create(void) {
  CMuteQueue *q = calloc(1, sizeof(CMuteQueue));
  atomic_init(&q->head, 0);
  atomic_init(&q->tail, 0);
  return q;
}

void cmute_destroy(CMuteQueue *q) { free(q); }

int cmute_push(CMuteQueue *q, CMuteEvent e) {
  uint64_t h = atomic_load_explicit(&q->head, memory_order_relaxed);
  uint64_t t = atomic_load_explicit(&q->tail, memory_order_acquire);
  if (h - t >= CMUTE_CAP) return 0;
  q->items[h % CMUTE_CAP] = e;
  atomic_store_explicit(&q->head, h + 1, memory_order_release);
  return 1;
}

int cmute_pop(CMuteQueue *q, CMuteEvent *e) {
  uint64_t t = atomic_load_explicit(&q->tail, memory_order_relaxed);
  uint64_t h = atomic_load_explicit(&q->head, memory_order_acquire);
  if (t == h) return 0;
  *e = q->items[t % CMUTE_CAP];
  atomic_store_explicit(&q->tail, t + 1, memory_order_release);
  return 1;
}
