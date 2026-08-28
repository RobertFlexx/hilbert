#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void *hilbert_gc_alloc(size_t);
void *hilbert_gc_alloc_atomic(size_t);
void hilbert_gc_collect(void);
void hilbert_gc_enable(void);
void hilbert_gc_disable(void);
int hilbert_gc_is_enabled(void);
int hilbert_gc_add_root(void **);
void hilbert_gc_remove_root(void **);
void hilbert_gc_register_thread(void);
void hilbert_gc_unregister_thread(void);
uint64_t hilbert_gc_live_bytes(void);
uint64_t hilbert_gc_heap_bytes(void);
uint64_t hilbert_gc_collection_count(void);

typedef void (*hilbert_task_proc)(void);
void *hilbert_rt_task_start(hilbert_task_proc);
void hilbert_rt_task_await(void *);
int32_t hilbert_rt_task_join(void *);

static volatile char *global_root;
static volatile int task_ok;

static void nap(long ns)
{
    struct timespec ts = {0, ns};
    (void)nanosleep(&ts, NULL);
}

static void task_body(void)
{
    volatile char *keep = hilbert_gc_alloc(256);
    strcpy((char *)keep, "task stack root");
    nap(150000000L);
    task_ok = strcmp((const char *)keep, "task stack root") == 0;
}

int main(void)
{
    volatile char *stack_root;
    void *explicit_root = NULL;
    void *task;
    uint64_t before;
    int i;

    hilbert_gc_register_thread();
    stack_root = hilbert_gc_alloc(64);
    strcpy((char *)stack_root, "stack root");
    global_root = hilbert_gc_alloc(64);
    strcpy((char *)global_root, "global root");

    explicit_root = hilbert_gc_alloc(96);
    strcpy((char *)explicit_root, "explicit root");
    if (!hilbert_gc_add_root(&explicit_root)) return 10;

    for (i = 0; i < 30000; ++i) (void)hilbert_gc_alloc(128);
    (void)hilbert_gc_alloc_atomic(2u * 1024u * 1024u);
    before = hilbert_gc_collection_count();
    hilbert_gc_collect();
    if (hilbert_gc_collection_count() <= before) return 11;
    if (strcmp((const char *)stack_root, "stack root")) return 12;
    if (strcmp((const char *)global_root, "global root")) return 13;
    if (strcmp((const char *)explicit_root, "explicit root")) return 14;

    task = hilbert_rt_task_start(task_body);
    if (!task) return 15;
    nap(30000000L);
    for (i = 0; i < 6000; ++i) (void)hilbert_gc_alloc_atomic(80);
    hilbert_gc_collect();
    if (hilbert_rt_task_join(task) != 0) return 19;
    /* Handles are monotonic tokens, not freed heap addresses.  A stale or
       duplicate join must fail cleanly instead of becoming a use-after-free. */
    if (hilbert_rt_task_join(task) == 0) return 20;
    if (!task_ok) return 16;

    hilbert_gc_disable();
    if (hilbert_gc_is_enabled()) return 17;
    (void)hilbert_gc_alloc(32);
    hilbert_gc_enable();
    if (!hilbert_gc_is_enabled()) return 18;

    hilbert_gc_remove_root(&explicit_root);
    explicit_root = NULL;
    hilbert_gc_collect();

    printf("gc ok: live=%llu heap=%llu collections=%llu\n",
           (unsigned long long)hilbert_gc_live_bytes(),
           (unsigned long long)hilbert_gc_heap_bytes(),
           (unsigned long long)hilbert_gc_collection_count());
    hilbert_gc_unregister_thread();
    return 0;
}
