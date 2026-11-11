#ifndef RTATOMICS_H
#define RTATOMICS_H

#include <stdint.h>

// Lock-free counters and float peaks shared between the IO thread (single writer) and the
// status thread. Opaque handle so Swift never has to import _Atomic types.
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

#endif
