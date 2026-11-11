#ifndef TAPATOMICS_H
#define TAPATOMICS_H

#include <stdint.h>

// Lock-free counters and float peaks shared between the IO thread (single writer) and readers.
// Opaque handles so Swift never has to import _Atomic types.
typedef struct RTStats RTStats;

RTStats *rt_create(int nCounters, int nFloats);
void rt_destroy(RTStats *s);

void rt_add(RTStats *s, int i, uint64_t d);
void rt_store(RTStats *s, int i, uint64_t v);
uint64_t rt_load(RTStats *s, int i);

void rt_fmax(RTStats *s, int i, float x);   // raise to x if larger
float rt_ftake(RTStats *s, int i);          // read and reset to 0
void rt_fstore(RTStats *s, int i, float x);
float rt_fload(RTStats *s, int i);

// Single-pointer slot for handing an object to the IO thread without locks.
// IO thread:   p = rt_slot_acquire(s); ...use p...; rt_slot_release(s);
// Other thread: old = rt_slot_exchange(s, new); then wait until rt_slot_busy(s) == 0 has been
// observed once; after that no IO cycle can still be using `old` (seq_cst Dekker argument:
// a cycle that marks itself busy after that observation loads the new pointer).
typedef struct RTSlot RTSlot;
RTSlot *rt_slot_create(void);
void rt_slot_destroy(RTSlot *s);
void *rt_slot_acquire(RTSlot *s);
void rt_slot_release(RTSlot *s);
void *rt_slot_exchange(RTSlot *s, void *p);
void *rt_slot_peek(RTSlot *s);
int rt_slot_busy(RTSlot *s);

#endif
