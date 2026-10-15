// Lock-free single-producer / single-consumer ring of interleaved stereo float frames.
// Safe to use from a Core Audio IO thread: no locks, no allocation after creation.
#pragma once
#include <stdint.h>

typedef struct CRing CRing;

CRing *cring_create(uint32_t capacityFrames);
void cring_destroy(CRing *r);
uint32_t cring_readable(const CRing *r);
uint32_t cring_writable(const CRing *r);
// Copies up to `frames` stereo frames; returns how many were written / read.
uint32_t cring_write(CRing *r, const float *interleaved, uint32_t frames);
uint32_t cring_read(CRing *r, float *interleaved, uint32_t frames);
// Consumer side only: drop everything currently readable.
void cring_clear(CRing *r);
