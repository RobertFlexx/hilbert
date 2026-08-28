#define _GNU_SOURCE
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void *hilbert_gc_alloc(size_t);
void *hilbert_gc_alloc_atomic(size_t);
void hilbert_gc_collect(void);
void hilbert_gc_register_thread(void);
void hilbert_gc_unregister_thread(void);
typedef void (*hilbert_task_proc)(void);
void *hilbert_rt_task_start(hilbert_task_proc);
void hilbert_rt_task_await(void *);

static _Atomic int workers_done;
static _Atomic int workers_bad;

static void worker(void)
{
    volatile uint64_t *keep = hilbert_gc_alloc(16 * sizeof(uint64_t));
    int i;
    keep[0] = UINT64_C(0x48494c42455254);
    for (i = 0; i < 18000; ++i) {
        size_t n = (size_t)((i % 3000) + 1);
        unsigned char *p = (i & 1) ? hilbert_gc_alloc(n) : hilbert_gc_alloc_atomic(n);
        p[0] = (unsigned char)i;
        p[n - 1] = (unsigned char)(i >> 3);
        if ((i % 257) == 0 && keep[0] != UINT64_C(0x48494c42455254))
            atomic_store(&workers_bad, 1);
        if ((i % 1024) == 0) {
            void *manual = malloc(4096);
            if (!manual) abort();
            memset(manual, i, 4096);
            free(manual);
        }
    }
    if (keep[0] != UINT64_C(0x48494c42455254)) atomic_store(&workers_bad, 1);
    atomic_fetch_add(&workers_done, 1);
}

int main(void)
{
    enum { N = 6 };
    void *tasks[N];
    int i;
    struct timespec nap = {0, 1000000L};

    hilbert_gc_register_thread();
    for (i = 0; i < N; ++i) {
        tasks[i] = hilbert_rt_task_start(worker);
        if (!tasks[i]) return 10 + i;
    }
    while (atomic_load(&workers_done) != N) {
        hilbert_gc_collect();
        (void)nanosleep(&nap, NULL);
    }
    for (i = 0; i < N; ++i) hilbert_rt_task_await(tasks[i]);
    if (atomic_load(&workers_bad)) return 30;
    hilbert_gc_collect();
    hilbert_gc_unregister_thread();
    puts("gc stress ok");
    return 0;
}
