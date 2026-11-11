#include "TapAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct RTStats {
    int nc, nf;
    _Atomic uint64_t *c;
    _Atomic uint32_t *f;
};

RTStats *rt_create(int nc, int nf) {
    RTStats *s = calloc(1, sizeof(RTStats));
    s->nc = nc; s->nf = nf;
    s->c = calloc((size_t)nc, sizeof(_Atomic uint64_t));
    s->f = calloc((size_t)nf, sizeof(_Atomic uint32_t));
    return s;
}

void rt_destroy(RTStats *s) { if (!s) return; free((void *)s->c); free((void *)s->f); free(s); }

void rt_add(RTStats *s, int i, uint64_t d) { atomic_fetch_add_explicit(&s->c[i], d, memory_order_relaxed); }
void rt_store(RTStats *s, int i, uint64_t v) { atomic_store_explicit(&s->c[i], v, memory_order_relaxed); }
uint64_t rt_load(RTStats *s, int i) { return atomic_load_explicit(&s->c[i], memory_order_relaxed); }

static inline float b2f(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }
static inline uint32_t f2b(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }

void rt_fmax(RTStats *s, int i, float x) {
    uint32_t old = atomic_load_explicit(&s->f[i], memory_order_relaxed);
    while (x > b2f(old)) {
        if (atomic_compare_exchange_weak_explicit(&s->f[i], &old, f2b(x), memory_order_relaxed, memory_order_relaxed)) break;
    }
}
float rt_ftake(RTStats *s, int i) { return b2f(atomic_exchange_explicit(&s->f[i], 0u, memory_order_relaxed)); }
void rt_fstore(RTStats *s, int i, float x) { atomic_store_explicit(&s->f[i], f2b(x), memory_order_relaxed); }
float rt_fload(RTStats *s, int i) { return b2f(atomic_load_explicit(&s->f[i], memory_order_relaxed)); }

struct RTSlot {
    _Atomic(void *) ptr;
    _Atomic int busy;
};

RTSlot *rt_slot_create(void) { return calloc(1, sizeof(RTSlot)); }
void rt_slot_destroy(RTSlot *s) { free(s); }

void *rt_slot_acquire(RTSlot *s) {
    atomic_store(&s->busy, 1);       // seq_cst
    return atomic_load(&s->ptr);     // seq_cst
}
void rt_slot_release(RTSlot *s) { atomic_store(&s->busy, 0); }
void *rt_slot_exchange(RTSlot *s, void *p) { return atomic_exchange(&s->ptr, p); }
void *rt_slot_peek(RTSlot *s) { return atomic_load(&s->ptr); }
int rt_slot_busy(RTSlot *s) { return atomic_load(&s->busy); }
