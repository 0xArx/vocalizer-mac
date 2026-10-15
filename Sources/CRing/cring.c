#include "cring.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct CRing {
  uint32_t cap; // frames, power of two
  float *data;  // cap * 2 floats
  _Atomic uint64_t head; // frames written
  _Atomic uint64_t tail; // frames read
};

CRing *cring_create(uint32_t capacityFrames) {
  uint32_t cap = 1;
  while (cap < capacityFrames) cap <<= 1;
  CRing *r = calloc(1, sizeof(CRing));
  r->cap = cap;
  r->data = calloc((size_t)cap * 2, sizeof(float));
  atomic_init(&r->head, 0);
  atomic_init(&r->tail, 0);
  return r;
}

void cring_destroy(CRing *r) {
  if (!r) return;
  free(r->data);
  free(r);
}

uint32_t cring_readable(const CRing *r) {
  return (uint32_t)(atomic_load_explicit(&((CRing *)r)->head, memory_order_acquire) -
                    atomic_load_explicit(&((CRing *)r)->tail, memory_order_acquire));
}

uint32_t cring_writable(const CRing *r) { return r->cap - cring_readable(r); }

uint32_t cring_write(CRing *r, const float *src, uint32_t frames) {
  uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
  uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
  uint32_t space = r->cap - (uint32_t)(head - tail);
  if (frames > space) frames = space;
  uint32_t pos = (uint32_t)(head & (r->cap - 1));
  uint32_t first = r->cap - pos < frames ? r->cap - pos : frames;
  memcpy(r->data + pos * 2, src, (size_t)first * 2 * sizeof(float));
  memcpy(r->data, src + first * 2, (size_t)(frames - first) * 2 * sizeof(float));
  atomic_store_explicit(&r->head, head + frames, memory_order_release);
  return frames;
}

uint32_t cring_read(CRing *r, float *dst, uint32_t frames) {
  uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
  uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
  uint32_t avail = (uint32_t)(head - tail);
  if (frames > avail) frames = avail;
  uint32_t pos = (uint32_t)(tail & (r->cap - 1));
  uint32_t first = r->cap - pos < frames ? r->cap - pos : frames;
  memcpy(dst, r->data + pos * 2, (size_t)first * 2 * sizeof(float));
  memcpy(dst + first * 2, r->data, (size_t)(frames - first) * 2 * sizeof(float));
  atomic_store_explicit(&r->tail, tail + frames, memory_order_release);
  return frames;
}

void cring_clear(CRing *r) {
  atomic_store_explicit(&r->tail, atomic_load_explicit(&r->head, memory_order_acquire), memory_order_release);
}
