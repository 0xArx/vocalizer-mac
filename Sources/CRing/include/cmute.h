// Lock-free single-producer / single-consumer queue of mute events, for the IO thread.
// Times are input-frame indices (the capture counter); the IO thread adds the playback delay.
#pragma once
#include <stdint.h>

typedef struct {
  int64_t start;   // first frame to mute (input frame index)
  int64_t end;     // one past the last frame
  int32_t id;      // provisional ranges can be cancelled by id
  int32_t kind;    // 0 = mute (final), 1 = mute (provisional), 2 = cancel provisional `id`
} CMuteEvent;

typedef struct CMuteQueue CMuteQueue;

CMuteQueue *cmute_create(void);
void cmute_destroy(CMuteQueue *q);
// Producer: returns 0 if the queue is full (event dropped).
int cmute_push(CMuteQueue *q, CMuteEvent e);
// Consumer: returns 1 and fills *e if an event was waiting.
int cmute_pop(CMuteQueue *q, CMuteEvent *e);
