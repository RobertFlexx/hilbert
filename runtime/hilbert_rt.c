/*
 * Hilbert native runtime.
 *
 * The managed heap is non-moving.  That keeps REF values stable
 * across C calls and makes the collector a good fit for a systems language.
 * Small and medium objects come from size-class slabs (64 KiB minimum);
 * large objects use mmap.
 * Collection is conservative mark/sweep with stop-the-world stack scanning for
 * Hilbert-managed pthreads.  Raw POINTER values and Memory.* allocations are
 * outside the collector.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if !defined(__linux__) || !defined(__x86_64__)
#error "Hilbert 1.0 runtime currently requires x86-64 Linux"
#endif

typedef void (*hilbert_task_proc)(void);
typedef void *(*hilbert_native_thread_proc)(void *);

__attribute__((noreturn)) void hilbert_rt_panic(const char *message);

enum {
    HGC_ALLOCATED = 1u << 0,
    HGC_MARKED    = 1u << 1,
    HGC_ATOMIC    = 1u << 2,
    HGC_LARGE     = 1u << 3
};

#define HGC_MAGIC       UINT32_C(0x48474331) /* HGC1 */
#define HGC_SLAB_BYTES  (64u * 1024u)
#define HGC_PAGE_SHIFT  12u
#define HGC_PAGE_BYTES  (1u << HGC_PAGE_SHIFT)
#define HGC_CLASS_COUNT 11u
#define HGC_MIN_TRIGGER (8u * 1024u * 1024u)
#define HGC_LOAD_NUM    7u
#define HGC_LOAD_DEN    10u

static const size_t hgc_classes[HGC_CLASS_COUNT] = {
    16u, 32u, 64u, 128u, 256u, 512u, 1024u, 2048u, 4096u, 8192u, 16384u
};

struct hgc_slab;
struct hgc_large;

struct hgc_header {
    uint32_t magic;
    uint16_t flags;
    uint16_t class_index;
    size_t requested;
    void *owner;
    struct hgc_header *next_free;
};

struct hgc_slab {
    void *mem;
    size_t map_size;
    size_t slot_size;
    size_t payload_size;
    uint32_t slot_count;
    uint32_t free_count;
    struct hgc_header *free_list;
    struct hgc_slab *next;
};

struct hgc_large {
    void *mapping;
    size_t map_size;
    struct hgc_header *header;
    struct hgc_large *next;
};

enum hgc_owner_kind { HGC_OWNER_NONE = 0, HGC_OWNER_SLAB = 1, HGC_OWNER_LARGE = 2 };
struct hgc_page_entry {
    uintptr_t key; /* page number + 2; 0 empty, 1 tombstone */
    uint8_t kind;
    void *owner;
};

struct hgc_thread {
    pthread_t tid;
    uintptr_t stack_lo;
    uintptr_t stack_hi;
    _Atomic uintptr_t stopped_sp;
    _Atomic int paused;
    struct hgc_thread *next;
};

struct hgc_root {
    void **slot;
    struct hgc_root *next;
};

struct hilbert_task_handle {
    pthread_t thread;
    hilbert_task_proc proc;
    uintptr_t token;
    struct hilbert_task_handle *next;
};

struct hilbert_native_thread_start {
    hilbert_native_thread_proc proc;
    void *data;
};

struct hilbert_gc_stats {
    uint64_t live_bytes;
    uint64_t heap_bytes;
    uint64_t allocated_bytes;
    uint64_t collections;
    uint64_t last_pause_ns;
    uint64_t max_pause_ns;
    uint64_t object_count;
};

static pthread_once_t hgc_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t hgc_heap_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t hgc_thread_lock = PTHREAD_MUTEX_INITIALIZER;
static struct hgc_slab *hgc_slabs[HGC_CLASS_COUNT];
static struct hgc_slab *hgc_active_slab[HGC_CLASS_COUNT];
static struct hgc_large *hgc_large_objects;
static struct hgc_page_entry *hgc_pages;
static size_t hgc_page_cap;
static size_t hgc_page_used;
static size_t hgc_page_tombs;
static uintptr_t hgc_heap_min = UINTPTR_MAX;
static uintptr_t hgc_heap_max;
static struct hgc_thread *hgc_threads;
static struct hgc_root *hgc_roots;
static _Thread_local struct hgc_thread *hgc_tls_thread;
static _Atomic int hgc_world_stopped;
static _Atomic int hgc_enabled = 1;
static pthread_mutex_t hilbert_task_lock = PTHREAD_MUTEX_INITIALIZER;
static struct hilbert_task_handle *hilbert_tasks;
static uintptr_t hilbert_next_task_token = 1u;
static uint64_t hgc_live_bytes;
static uint64_t hgc_heap_bytes;
static uint64_t hgc_allocated_bytes;
static uint64_t hgc_since_collection;
static uint64_t hgc_collection_count;
static uint64_t hgc_last_pause_ns;
static uint64_t hgc_max_pause_ns;
static uint64_t hgc_object_count;
static uint64_t hgc_next_trigger = HGC_MIN_TRIGGER;
static struct hgc_header **hgc_mark_items;
static size_t hgc_mark_capacity;

extern char __data_start;
extern char _end;

static size_t hgc_align_up(size_t n, size_t a)
{
    return (n + a - 1u) & ~(a - 1u);
}

static uint64_t hgc_now_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static uintptr_t hgc_page_key(uintptr_t address)
{
    return (address >> HGC_PAGE_SHIFT) + 2u;
}

static size_t hgc_hash(uintptr_t key, size_t cap)
{
    key ^= key >> 33;
    key *= UINT64_C(0xff51afd7ed558ccd);
    key ^= key >> 33;
    return (size_t)key & (cap - 1u);
}

static int hgc_page_rehash(size_t new_cap)
{
    struct hgc_page_entry *old = hgc_pages;
    size_t old_cap = hgc_page_cap;
    struct hgc_page_entry *fresh = calloc(new_cap, sizeof(*fresh));
    size_t i;
    if (!fresh) return 0;
    hgc_pages = fresh;
    hgc_page_cap = new_cap;
    hgc_page_used = 0;
    hgc_page_tombs = 0;
    if (old) {
        for (i = 0; i < old_cap; ++i) {
            if (old[i].key > 1u) {
                size_t p = hgc_hash(old[i].key, hgc_page_cap);
                while (hgc_pages[p].key > 1u) p = (p + 1u) & (hgc_page_cap - 1u);
                hgc_pages[p] = old[i];
                ++hgc_page_used;
            }
        }
        free(old);
    }
    return 1;
}

static int hgc_page_reserve(void)
{
    size_t occupied;
    if (!hgc_pages) return hgc_page_rehash(4096u);
    occupied = hgc_page_used + hgc_page_tombs;
    if ((occupied + 1u) * HGC_LOAD_DEN >= hgc_page_cap * HGC_LOAD_NUM) {
        /* Tombstones are useful for probing, but an allocation/free-heavy
           program can otherwise fill the table with dead probe entries.
           Rehash in place when live occupancy is still low; grow only when
           the live set actually needs it. */
        if ((hgc_page_used + 1u) * HGC_LOAD_DEN < hgc_page_cap * (HGC_LOAD_NUM / 2u + 1u))
            return hgc_page_rehash(hgc_page_cap);
        if (hgc_page_cap > SIZE_MAX / 2u) return 0;
        return hgc_page_rehash(hgc_page_cap * 2u);
    }
    return 1;
}

static int hgc_page_put(uintptr_t page_addr, uint8_t kind, void *owner)
{
    uintptr_t key = hgc_page_key(page_addr);
    size_t p, tomb = SIZE_MAX;
    if (!hgc_page_reserve()) return 0;
    p = hgc_hash(key, hgc_page_cap);
    for (;;) {
        if (hgc_pages[p].key == 0u) {
            if (tomb != SIZE_MAX) { p = tomb; --hgc_page_tombs; }
            hgc_pages[p].key = key;
            hgc_pages[p].kind = kind;
            hgc_pages[p].owner = owner;
            ++hgc_page_used;
            return 1;
        }
        if (hgc_pages[p].key == 1u) {
            if (tomb == SIZE_MAX) tomb = p;
        } else if (hgc_pages[p].key == key) {
            hgc_pages[p].kind = kind;
            hgc_pages[p].owner = owner;
            return 1;
        }
        p = (p + 1u) & (hgc_page_cap - 1u);
    }
}

static void hgc_page_remove(uintptr_t page_addr)
{
    uintptr_t key;
    size_t p;
    if (!hgc_pages) return;
    key = hgc_page_key(page_addr);
    p = hgc_hash(key, hgc_page_cap);
    while (hgc_pages[p].key != 0u) {
        if (hgc_pages[p].key == key) {
            hgc_pages[p].key = 1u;
            hgc_pages[p].kind = 0;
            hgc_pages[p].owner = NULL;
            if (hgc_page_used) --hgc_page_used;
            ++hgc_page_tombs;
            return;
        }
        p = (p + 1u) & (hgc_page_cap - 1u);
    }
}

static struct hgc_page_entry hgc_page_get(uintptr_t address)
{
    struct hgc_page_entry none = {0, 0, NULL};
    uintptr_t key;
    size_t p;
    if (!hgc_pages) return none;
    key = hgc_page_key(address);
    p = hgc_hash(key, hgc_page_cap);
    while (hgc_pages[p].key != 0u) {
        if (hgc_pages[p].key == key) return hgc_pages[p];
        p = (p + 1u) & (hgc_page_cap - 1u);
    }
    return none;
}

static void hgc_map_range(void *mem, size_t bytes, uint8_t kind, void *owner)
{
    uintptr_t p = (uintptr_t)mem & ~(uintptr_t)(HGC_PAGE_BYTES - 1u);
    uintptr_t end = hgc_align_up((uintptr_t)mem + bytes, HGC_PAGE_BYTES);
    while (p < end) {
        if (!hgc_page_put(p, kind, owner)) {
            fputs("hilbert: GC page map allocation failed\n", stderr);
            abort();
        }
        p += HGC_PAGE_BYTES;
    }
}

static void hgc_unmap_range(void *mem, size_t bytes)
{
    uintptr_t p = (uintptr_t)mem & ~(uintptr_t)(HGC_PAGE_BYTES - 1u);
    uintptr_t end = hgc_align_up((uintptr_t)mem + bytes, HGC_PAGE_BYTES);
    while (p < end) {
        hgc_page_remove(p);
        p += HGC_PAGE_BYTES;
    }
}

static void hgc_note_heap_range(void *mem, size_t bytes)
{
    uintptr_t lo = (uintptr_t)mem;
    uintptr_t hi = lo + bytes;
    if (lo < hgc_heap_min) hgc_heap_min = lo;
    if (hi > hgc_heap_max) hgc_heap_max = hi;
}

static size_t hgc_header_bytes(void)
{
    return hgc_align_up(sizeof(struct hgc_header), 16u);
}

static void *hgc_payload(struct hgc_header *h)
{
    return (void *)((unsigned char *)h + hgc_header_bytes());
}

static unsigned hgc_class_for(size_t bytes)
{
    unsigned i;
    for (i = 0; i < HGC_CLASS_COUNT; ++i) if (bytes <= hgc_classes[i]) return i;
    return HGC_CLASS_COUNT;
}

static struct hgc_slab *hgc_new_slab(unsigned class_index)
{
    struct hgc_slab *s;
    size_t slot_size, i;
    unsigned char *p;
    struct hgc_header *h;

    s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    slot_size = hgc_align_up(hgc_header_bytes() + hgc_classes[class_index], 16u);
    s->map_size = HGC_SLAB_BYTES;
    /* Keep enough objects in the larger size classes that a 5-16 KiB hot
       allocation stream does not degenerate into one mmap per object. */
    while ((s->map_size / slot_size) < 8u) {
        if (s->map_size > SIZE_MAX / 2u) { free(s); return NULL; }
        s->map_size *= 2u;
    }
    s->mem = mmap(NULL, s->map_size, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (s->mem == MAP_FAILED) {
        free(s);
        return NULL;
    }
    s->slot_size = slot_size;
    s->payload_size = hgc_classes[class_index];
    s->slot_count = (uint32_t)(s->map_size / slot_size);
    s->free_count = s->slot_count;
    p = (unsigned char *)s->mem;
    for (i = 0; i < s->slot_count; ++i) {
        h = (struct hgc_header *)(p + i * slot_size);
        memset(h, 0, hgc_header_bytes());
        h->magic = HGC_MAGIC;
        h->class_index = (uint16_t)class_index;
        h->owner = s;
        h->next_free = s->free_list;
        s->free_list = h;
    }
    s->next = hgc_slabs[class_index];
    hgc_slabs[class_index] = s;
    hgc_active_slab[class_index] = s;
    hgc_map_range(s->mem, s->map_size, HGC_OWNER_SLAB, s);
    hgc_note_heap_range(s->mem, s->map_size);
    hgc_heap_bytes += s->map_size;
    return s;
}

static struct hgc_header *hgc_alloc_small(size_t bytes, int atomic_payload)
{
    unsigned class_index = hgc_class_for(bytes);
    struct hgc_slab *s = hgc_active_slab[class_index];
    struct hgc_header *h;

    if (!s || !s->free_list) {
        /* Usually collection has already remembered a slab with free slots.
           The scan is only a recovery path after unusual state changes. */
        s = hgc_slabs[class_index];
        while (s && !s->free_list) s = s->next;
        if (!s) s = hgc_new_slab(class_index);
        hgc_active_slab[class_index] = s;
    }
    if (!s) return NULL;
    h = s->free_list;
    s->free_list = h->next_free;
    --s->free_count;
    if (!s->free_list) hgc_active_slab[class_index] = NULL;
    h->flags = HGC_ALLOCATED | (atomic_payload ? HGC_ATOMIC : 0u);
    h->requested = bytes;
    h->next_free = NULL;
    return h;
}

static struct hgc_header *hgc_alloc_large(size_t bytes, int atomic_payload)
{
    struct hgc_large *m;
    struct hgc_header *h;
    size_t need, map_size;
    size_t header = hgc_header_bytes();
    if (bytes > SIZE_MAX - header) return NULL;
    need = header + bytes;
    if (need > SIZE_MAX - (HGC_PAGE_BYTES - 1u)) return NULL;
    map_size = hgc_align_up(need, HGC_PAGE_BYTES);
    void *mapping = mmap(NULL, map_size, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapping == MAP_FAILED) return NULL;
    m = calloc(1, sizeof(*m));
    if (!m) {
        munmap(mapping, map_size);
        return NULL;
    }
    h = (struct hgc_header *)mapping;
    memset(h, 0, hgc_header_bytes());
    h->magic = HGC_MAGIC;
    h->flags = HGC_ALLOCATED | HGC_LARGE | (atomic_payload ? HGC_ATOMIC : 0u);
    h->class_index = UINT16_MAX;
    h->requested = bytes;
    h->owner = m;
    m->mapping = mapping;
    m->map_size = map_size;
    m->header = h;
    m->next = hgc_large_objects;
    hgc_large_objects = m;
    hgc_map_range(mapping, map_size, HGC_OWNER_LARGE, m);
    hgc_note_heap_range(mapping, map_size);
    hgc_heap_bytes += map_size;
    return h;
}

static struct hgc_header *hgc_header_for_candidate(uintptr_t value)
{
    struct hgc_page_entry e;
    struct hgc_header *h;
    uintptr_t payload, end;
    if (value < hgc_heap_min || value >= hgc_heap_max) return NULL;
    e = hgc_page_get(value);
    if (e.kind == HGC_OWNER_SLAB) {
        struct hgc_slab *s = (struct hgc_slab *)e.owner;
        uintptr_t base = (uintptr_t)s->mem;
        size_t off, idx;
        if (value < base || value >= base + s->map_size) return NULL;
        off = (size_t)(value - base);
        idx = off / s->slot_size;
        if (idx >= s->slot_count) return NULL;
        h = (struct hgc_header *)((unsigned char *)s->mem + idx * s->slot_size);
    } else if (e.kind == HGC_OWNER_LARGE) {
        struct hgc_large *m = (struct hgc_large *)e.owner;
        h = m->header;
    } else {
        return NULL;
    }
    if (h->magic != HGC_MAGIC || !(h->flags & HGC_ALLOCATED)) return NULL;
    payload = (uintptr_t)hgc_payload(h);
    end = payload + (uintptr_t)h->requested;
    if (value < payload || value >= end) return NULL;
    return h;
}

struct hgc_mark_stack {
    struct hgc_header **items;
    size_t count;
    size_t cap;
};

static void hgc_mark_push(struct hgc_mark_stack *st, struct hgc_header *h)
{
    if (h->flags & HGC_MARKED) return;
    if (st->count == st->cap) {
        fputs("hilbert: GC mark stack invariant failed\n", stderr);
        abort();
    }
    h->flags |= HGC_MARKED;
    st->items[st->count++] = h;
}

static void hgc_mark_candidate(struct hgc_mark_stack *st, uintptr_t candidate)
{
    struct hgc_header *h = hgc_header_for_candidate(candidate);
    if (h) hgc_mark_push(st, h);
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((no_sanitize("address", "undefined")))
#endif
static void hgc_scan_words(struct hgc_mark_stack *st, const void *begin, const void *end)
{
    uintptr_t p = hgc_align_up((uintptr_t)begin, sizeof(uintptr_t));
    uintptr_t e = (uintptr_t)end & ~(uintptr_t)(sizeof(uintptr_t) - 1u);
    while (p < e) {
        uintptr_t v;
        memcpy(&v, (const void *)p, sizeof(v));
        hgc_mark_candidate(st, v);
        p += sizeof(uintptr_t);
    }
}

static void hgc_mark_transitive(struct hgc_mark_stack *st)
{
    while (st->count) {
        struct hgc_header *h = st->items[--st->count];
        if (!(h->flags & HGC_ATOMIC)) {
            unsigned char *p = (unsigned char *)hgc_payload(h);
            hgc_scan_words(st, p, p + h->requested);
        }
    }
}

static void hgc_pause_handler(int signo)
{
    uintptr_t sp;
    (void)signo;
    if (!hgc_tls_thread) return;
    sp = (uintptr_t)&sp;
    atomic_store_explicit(&hgc_tls_thread->stopped_sp, sp, memory_order_release);
    atomic_store_explicit(&hgc_tls_thread->paused, 1, memory_order_release);
    while (atomic_load_explicit(&hgc_world_stopped, memory_order_acquire)) {
        __asm__ __volatile__("pause" ::: "memory");
    }
    atomic_store_explicit(&hgc_tls_thread->paused, 0, memory_order_release);
}

static void hgc_runtime_init_once(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = hgc_pause_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    if (sigaction(SIGUSR2, &sa, NULL) != 0) {
        perror("hilbert: sigaction(SIGUSR2)");
        abort();
    }
    if (!hgc_page_rehash(4096u)) {
        fputs("hilbert: cannot initialize GC page map\n", stderr);
        abort();
    }
}

void hilbert_gc_register_thread(void)
{
    pthread_attr_t attr;
    void *stack = NULL;
    size_t stack_size = 0;
    struct hgc_thread *t;
    pthread_once(&hgc_once, hgc_runtime_init_once);
    if (hgc_tls_thread) return;
    t = calloc(1, sizeof(*t));
    if (!t) abort();
    t->tid = pthread_self();
    if (pthread_getattr_np(t->tid, &attr) == 0) {
        if (pthread_attr_getstack(&attr, &stack, &stack_size) == 0) {
            t->stack_lo = (uintptr_t)stack;
            t->stack_hi = t->stack_lo + stack_size;
        }
        pthread_attr_destroy(&attr);
    }
    if (!t->stack_hi) {
        uintptr_t here = (uintptr_t)&t;
        t->stack_lo = here > (8u * 1024u * 1024u) ? here - (8u * 1024u * 1024u) : 0;
        t->stack_hi = here + (1u * 1024u * 1024u);
    }
    hgc_tls_thread = t;
    pthread_mutex_lock(&hgc_thread_lock);
    t->next = hgc_threads;
    hgc_threads = t;
    pthread_mutex_unlock(&hgc_thread_lock);
}

void hilbert_gc_unregister_thread(void)
{
    struct hgc_thread **p;
    struct hgc_thread *t = hgc_tls_thread;
    if (!t) return;
    pthread_mutex_lock(&hgc_thread_lock);
    p = &hgc_threads;
    while (*p && *p != t) p = &(*p)->next;
    if (*p == t) *p = t->next;
    pthread_mutex_unlock(&hgc_thread_lock);
    hgc_tls_thread = NULL;
    free(t);
}

static void hgc_stop_world(void)
{
    struct hgc_thread *t;
    pthread_t self = pthread_self();
    uint64_t deadline = hgc_now_ns() + UINT64_C(2000000000);
    atomic_store_explicit(&hgc_world_stopped, 1, memory_order_release);
    pthread_mutex_lock(&hgc_thread_lock);
    for (t = hgc_threads; t; t = t->next) {
        if (!pthread_equal(t->tid, self)) {
            int rc = pthread_kill(t->tid, SIGUSR2);
            if (rc != 0) {
                /* A dead foreign thread which forgot to unregister must not
                   wedge every future collection. State 2 means unavailable. */
                atomic_store_explicit(&t->stopped_sp, t->stack_hi, memory_order_release);
                atomic_store_explicit(&t->paused, 2, memory_order_release);
            }
        }
    }
    for (t = hgc_threads; t; t = t->next) {
        if (!pthread_equal(t->tid, self)) {
            unsigned spins = 0;
            while (atomic_load_explicit(&t->paused, memory_order_acquire) == 0) {
                __asm__ __volatile__("pause" ::: "memory");
                if ((++spins & 0xffffu) == 0u) {
                    if (hgc_now_ns() >= deadline) {
                        fputs("hilbert: GC could not suspend a registered thread (SIGUSR2 blocked?)\n", stderr);
                        abort();
                    }
                    sched_yield();
                }
            }
        }
    }
}

static void hgc_resume_world(void)
{
    struct hgc_thread *t;
    pthread_t self = pthread_self();
    atomic_store_explicit(&hgc_world_stopped, 0, memory_order_release);
    for (t = hgc_threads; t; t = t->next) {
        if (!pthread_equal(t->tid, self)) {
            int state = atomic_load_explicit(&t->paused, memory_order_acquire);
            if (state == 1) {
                while (atomic_load_explicit(&t->paused, memory_order_acquire) == 1)
                    __asm__ __volatile__("pause" ::: "memory");
            } else if (state == 2) {
                atomic_store_explicit(&t->paused, 0, memory_order_release);
            }
        }
    }
    pthread_mutex_unlock(&hgc_thread_lock);
}

static void hgc_mark_roots(struct hgc_mark_stack *st)
{
    struct hgc_thread *t;
    pthread_t self = pthread_self();
    uintptr_t current_sp = (uintptr_t)&st;
    jmp_buf regs;

    (void)setjmp(regs);
    hgc_scan_words(st, &regs, (unsigned char *)&regs + sizeof(regs));
    hgc_scan_words(st, &__data_start, &_end);

    for (t = hgc_threads; t; t = t->next) {
        uintptr_t sp;
        if (pthread_equal(t->tid, self)) sp = current_sp;
        else sp = atomic_load_explicit(&t->stopped_sp, memory_order_acquire);
        if (sp < t->stack_lo) sp = t->stack_lo;
        if (sp > t->stack_hi) sp = t->stack_hi;
        hgc_scan_words(st, (void *)sp, (void *)t->stack_hi);
    }
    {
        struct hgc_root *r;
        for (r = hgc_roots; r; r = r->next) {
            if (r->slot) hgc_mark_candidate(st, (uintptr_t)*r->slot);
        }
    }
    hgc_mark_transitive(st);
}

static void hgc_release_empty_slabs(void)
{
    unsigned c;
    for (c = 0; c < HGC_CLASS_COUNT; ++c) {
        struct hgc_slab **p = &hgc_slabs[c];
        struct hgc_slab *first_free = NULL;
        int kept_empty = 0;
        while (*p) {
            struct hgc_slab *s = *p;
            if (s->free_list && first_free == NULL) first_free = s;
            if (s->free_count == s->slot_count) {
                if (!kept_empty) {
                    kept_empty = 1;
                    p = &s->next;
                } else {
                    if (first_free == s) first_free = NULL;
                    *p = s->next;
                    hgc_unmap_range(s->mem, s->map_size);
                    hgc_heap_bytes -= s->map_size;
                    munmap(s->mem, s->map_size);
                    free(s);
                }
            } else {
                p = &s->next;
            }
        }
        if (first_free == NULL) {
            struct hgc_slab *s = hgc_slabs[c];
            while (s && !s->free_list) s = s->next;
            first_free = s;
        }
        hgc_active_slab[c] = first_free;
    }
}

static void hgc_sweep(struct hgc_large **dead_large)
{
    unsigned c;
    uint64_t live = 0, count = 0;
    for (c = 0; c < HGC_CLASS_COUNT; ++c) {
        struct hgc_slab *s;
        for (s = hgc_slabs[c]; s; s = s->next) {
            uint32_t i;
            for (i = 0; i < s->slot_count; ++i) {
                struct hgc_header *h = (struct hgc_header *)((unsigned char *)s->mem + (size_t)i * s->slot_size);
                if (!(h->flags & HGC_ALLOCATED)) continue;
                if (h->flags & HGC_MARKED) {
                    h->flags &= (uint16_t)~HGC_MARKED;
                    live += h->requested;
                    ++count;
                } else {
                    h->flags = 0;
                    h->requested = 0;
                    h->next_free = s->free_list;
                    s->free_list = h;
                    ++s->free_count;
                }
            }
        }
        hgc_active_slab[c] = NULL;
        for (s = hgc_slabs[c]; s; s = s->next) {
            if (s->free_list) { hgc_active_slab[c] = s; break; }
        }
    }

    {
        struct hgc_large **p = &hgc_large_objects;
        while (*p) {
            struct hgc_large *m = *p;
            struct hgc_header *h = m->header;
            if (h->flags & HGC_MARKED) {
                h->flags &= (uint16_t)~HGC_MARKED;
                live += h->requested;
                ++count;
                p = &m->next;
            } else {
                *p = m->next;
                m->next = *dead_large;
                *dead_large = m;
            }
        }
    }

    hgc_live_bytes = live;
    hgc_object_count = count;
}

static void hgc_release_dead_large(struct hgc_large *dead)
{
    while (dead) {
        struct hgc_large *next = dead->next;
        hgc_unmap_range(dead->mapping, dead->map_size);
        hgc_heap_bytes -= dead->map_size;
        munmap(dead->mapping, dead->map_size);
        free(dead);
        dead = next;
    }
}

static void hgc_collect_locked(void)
{
    struct hgc_mark_stack st = {NULL, 0, 0};
    struct hgc_large *dead_large = NULL;
    uint64_t begin, end, target;
    size_t mark_cap;
    if (!atomic_load_explicit(&hgc_enabled, memory_order_relaxed)) return;
    hilbert_gc_register_thread();

    /* Do all libc allocation before suspending other threads.  A stopped
       thread may itself be inside malloc, so the pause window must not enter
       libc's allocator. */
    if (hgc_object_count > (uint64_t)(SIZE_MAX / sizeof(*st.items))) {
        fputs("hilbert: GC object table is too large to mark safely\n", stderr);
        abort();
    }
    mark_cap = hgc_object_count ? (size_t)hgc_object_count : 1u;
    if (mark_cap > hgc_mark_capacity) {
        struct hgc_header **fresh = realloc(hgc_mark_items, mark_cap * sizeof(*fresh));
        if (!fresh) {
            fputs("hilbert: GC mark stack allocation failed\n", stderr);
            abort();
        }
        hgc_mark_items = fresh;
        hgc_mark_capacity = mark_cap;
    }
    st.items = hgc_mark_items;
    st.cap = hgc_mark_capacity;

    begin = hgc_now_ns();
    hgc_stop_world();
    hgc_mark_roots(&st);
    hgc_sweep(&dead_large);
    hgc_resume_world();
    end = hgc_now_ns();

    /* The heap lock is still held, but mutator threads are running again.
       Releasing mappings and libc metadata here avoids allocator-lock
       deadlocks while keeping the managed heap itself unchanged. */
    hgc_release_dead_large(dead_large);
    hgc_release_empty_slabs();

    hgc_last_pause_ns = end >= begin ? end - begin : 0;
    if (hgc_last_pause_ns > hgc_max_pause_ns) hgc_max_pause_ns = hgc_last_pause_ns;
    ++hgc_collection_count;
    hgc_since_collection = 0;
    if (hgc_live_bytes > (UINT64_MAX - (2u * 1024u * 1024u)) / 2u) target = UINT64_MAX;
    else target = hgc_live_bytes * 2u + (2u * 1024u * 1024u);
    if (target < HGC_MIN_TRIGGER) target = HGC_MIN_TRIGGER;
    hgc_next_trigger = target;
}

static void *hgc_alloc_impl(size_t bytes, int atomic_payload)
{
    struct hgc_header *h;
    void *p;
    if (bytes == 0) bytes = 1;
    pthread_once(&hgc_once, hgc_runtime_init_once);
    hilbert_gc_register_thread();
    pthread_mutex_lock(&hgc_heap_lock);
    if (atomic_load_explicit(&hgc_enabled, memory_order_relaxed) &&
        hgc_since_collection >= hgc_next_trigger)
        hgc_collect_locked();
    if (bytes <= hgc_classes[HGC_CLASS_COUNT - 1u]) h = hgc_alloc_small(bytes, atomic_payload);
    else h = hgc_alloc_large(bytes, atomic_payload);
    if (!h) {
        hgc_collect_locked();
        if (bytes <= hgc_classes[HGC_CLASS_COUNT - 1u]) h = hgc_alloc_small(bytes, atomic_payload);
        else h = hgc_alloc_large(bytes, atomic_payload);
    }
    if (!h) {
        pthread_mutex_unlock(&hgc_heap_lock);
        return NULL;
    }
    p = hgc_payload(h);
    memset(p, 0, bytes);
    if (UINT64_MAX - hgc_live_bytes < (uint64_t)bytes) hgc_live_bytes = UINT64_MAX;
    else hgc_live_bytes += (uint64_t)bytes;
    if (UINT64_MAX - hgc_allocated_bytes < (uint64_t)bytes) hgc_allocated_bytes = UINT64_MAX;
    else hgc_allocated_bytes += (uint64_t)bytes;
    if (UINT64_MAX - hgc_since_collection < (uint64_t)bytes) hgc_since_collection = UINT64_MAX;
    else hgc_since_collection += (uint64_t)bytes;
    ++hgc_object_count;
    pthread_mutex_unlock(&hgc_heap_lock);
    return p;
}

void *hilbert_gc_try_alloc(size_t bytes)
{
    return hgc_alloc_impl(bytes, 0);
}

void *hilbert_gc_try_alloc_atomic(size_t bytes)
{
    return hgc_alloc_impl(bytes, 1);
}

static void *hgc_alloc_or_panic(size_t bytes, int atomic_payload)
{
    void *p = hgc_alloc_impl(bytes, atomic_payload);
    if (p == NULL) {
        fprintf(stderr, "hilbert: out of managed memory while allocating %zu bytes\n", bytes);
        abort();
    }
    return p;
}

void *hilbert_gc_alloc(size_t bytes)
{
    return hgc_alloc_or_panic(bytes, 0);
}

void *hilbert_gc_alloc_atomic(size_t bytes)
{
    return hgc_alloc_or_panic(bytes, 1);
}

void hilbert_gc_collect(void)
{
    pthread_once(&hgc_once, hgc_runtime_init_once);
    hilbert_gc_register_thread();
    pthread_mutex_lock(&hgc_heap_lock);
    hgc_collect_locked();
    pthread_mutex_unlock(&hgc_heap_lock);
}

void hilbert_gc_enable(void)
{
    atomic_store_explicit(&hgc_enabled, 1, memory_order_release);
}

void hilbert_gc_disable(void)
{
    atomic_store_explicit(&hgc_enabled, 0, memory_order_release);
}

int hilbert_gc_is_enabled(void)
{
    return atomic_load_explicit(&hgc_enabled, memory_order_acquire) != 0;
}

void hilbert_gc_set_trigger(size_t bytes)
{
    pthread_mutex_lock(&hgc_heap_lock);
    hgc_next_trigger = bytes < (1024u * 1024u) ? (1024u * 1024u) : bytes;
    pthread_mutex_unlock(&hgc_heap_lock);
}

int hilbert_gc_add_root(void **slot)
{
    struct hgc_root *r;
    if (!slot) return 0;
    r = malloc(sizeof(*r));
    if (!r) return 0;
    r->slot = slot;
    pthread_mutex_lock(&hgc_heap_lock);
    r->next = hgc_roots;
    hgc_roots = r;
    pthread_mutex_unlock(&hgc_heap_lock);
    return 1;
}

void hilbert_gc_remove_root(void **slot)
{
    struct hgc_root **p;
    pthread_mutex_lock(&hgc_heap_lock);
    p = &hgc_roots;
    while (*p) {
        if ((*p)->slot == slot) {
            struct hgc_root *dead = *p;
            *p = dead->next;
            pthread_mutex_unlock(&hgc_heap_lock);
            free(dead);
            return;
        }
        p = &(*p)->next;
    }
    pthread_mutex_unlock(&hgc_heap_lock);
}

struct hilbert_gc_stats hilbert_gc_get_stats(void)
{
    struct hilbert_gc_stats s;
    pthread_mutex_lock(&hgc_heap_lock);
    s.live_bytes = hgc_live_bytes;
    s.heap_bytes = hgc_heap_bytes;
    s.allocated_bytes = hgc_allocated_bytes;
    s.collections = hgc_collection_count;
    s.last_pause_ns = hgc_last_pause_ns;
    s.max_pause_ns = hgc_max_pause_ns;
    s.object_count = hgc_object_count;
    pthread_mutex_unlock(&hgc_heap_lock);
    return s;
}

static uint64_t hgc_read_stat(const uint64_t *value)
{
    uint64_t out;
    pthread_mutex_lock(&hgc_heap_lock);
    out = *value;
    pthread_mutex_unlock(&hgc_heap_lock);
    return out;
}

uint64_t hilbert_gc_live_bytes(void) { return hgc_read_stat(&hgc_live_bytes); }
uint64_t hilbert_gc_heap_bytes(void) { return hgc_read_stat(&hgc_heap_bytes); }
uint64_t hilbert_gc_allocated_bytes(void) { return hgc_read_stat(&hgc_allocated_bytes); }
uint64_t hilbert_gc_collection_count(void) { return hgc_read_stat(&hgc_collection_count); }
uint64_t hilbert_gc_last_pause_ns(void) { return hgc_read_stat(&hgc_last_pause_ns); }
uint64_t hilbert_gc_max_pause_ns(void) { return hgc_read_stat(&hgc_max_pause_ns); }
uint64_t hilbert_gc_object_count(void) { return hgc_read_stat(&hgc_object_count); }

static void *hilbert_task_entry(void *opaque)
{
    struct hilbert_task_handle *h = (struct hilbert_task_handle *)opaque;
    hilbert_gc_register_thread();
    h->proc();
    hilbert_gc_unregister_thread();
    return NULL;
}

static void *hilbert_native_thread_entry(void *opaque)
{
    struct hilbert_native_thread_start *start =
        (struct hilbert_native_thread_start *)opaque;
    hilbert_native_thread_proc proc = start->proc;
    void *data = start->data;
    void *result;
    free(start);
    hilbert_gc_register_thread();
    result = proc(data);
    hilbert_gc_unregister_thread();
    return result;
}

int32_t hilbert_rt_native_thread_create(uintptr_t *thread_out,
                                        hilbert_native_thread_proc proc,
                                        void *data)
{
    struct hilbert_native_thread_start *start;
    pthread_t thread;
    int rc;
    _Static_assert(sizeof(pthread_t) <= sizeof(uintptr_t),
                   "pthread_t does not fit a Hilbert NativeThread.Thread");
    if (thread_out == NULL || proc == NULL) {
        errno = EINVAL;
        return -1;
    }
    start = (struct hilbert_native_thread_start *)malloc(sizeof(*start));
    if (start == NULL) return -1;
    start->proc = proc;
    start->data = data;
    rc = pthread_create(&thread, NULL, hilbert_native_thread_entry, start);
    if (rc != 0) {
        free(start);
        errno = rc;
        return -1;
    }
    *thread_out = 0u;
    memcpy(thread_out, &thread, sizeof(thread));
    return 0;
}

int32_t hilbert_rt_native_thread_join(uintptr_t value)
{
    pthread_t thread;
    int rc;
    memset(&thread, 0, sizeof(thread));
    memcpy(&thread, &value, sizeof(thread));
    rc = pthread_join(thread, NULL);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    return 0;
}

int32_t hilbert_rt_native_thread_detach(uintptr_t value)
{
    pthread_t thread;
    int rc;
    memset(&thread, 0, sizeof(thread));
    memcpy(&thread, &value, sizeof(thread));
    rc = pthread_detach(thread);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    return 0;
}

void *hilbert_rt_task_start(hilbert_task_proc proc)
{
    struct hilbert_task_handle *h;
    uintptr_t token;
    int rc;
    if (proc == NULL) return NULL;
    h = (struct hilbert_task_handle *)calloc(1, sizeof(*h));
    if (h == NULL) return NULL;
    h->proc = proc;
    rc = pthread_create(&h->thread, NULL, hilbert_task_entry, h);
    if (rc != 0) {
        free(h);
        errno = rc;
        return NULL;
    }
    pthread_mutex_lock(&hilbert_task_lock);
    token = hilbert_next_task_token;
    if (token == 0u || token == UINTPTR_MAX) {
        pthread_mutex_unlock(&hilbert_task_lock);
        (void)pthread_join(h->thread, NULL);
        free(h);
        errno = EOVERFLOW;
        return NULL;
    }
    hilbert_next_task_token = token + 1u;
    h->token = token;
    h->next = hilbert_tasks;
    hilbert_tasks = h;
    pthread_mutex_unlock(&hilbert_task_lock);
    return (void *)token;
}

int32_t hilbert_rt_task_join(void *opaque)
{
    uintptr_t token = (uintptr_t)opaque;
    struct hilbert_task_handle **link;
    struct hilbert_task_handle *h;
    int rc;
    if (token == 0u) {
        errno = EINVAL;
        return -1;
    }
    pthread_mutex_lock(&hilbert_task_lock);
    link = &hilbert_tasks;
    while (*link && (*link)->token != token) link = &(*link)->next;
    if (!*link) {
        pthread_mutex_unlock(&hilbert_task_lock);
        errno = EINVAL;
        return -1;
    }
    h = *link;
    *link = h->next;
    pthread_mutex_unlock(&hilbert_task_lock);

    rc = pthread_join(h->thread, NULL);
    if (rc != 0) {
        pthread_mutex_lock(&hilbert_task_lock);
        h->next = hilbert_tasks;
        hilbert_tasks = h;
        pthread_mutex_unlock(&hilbert_task_lock);
        errno = rc;
        return -1;
    }
    free(h);
    return 0;
}

void hilbert_rt_task_await(void *opaque)
{
    if (hilbert_rt_task_join(opaque) != 0)
        hilbert_rt_panic("invalid or already joined task handle");
}

__attribute__((noreturn)) void hilbert_rt_panic(const char *message)
{
    if (message && *message) fprintf(stderr, "hilbert: runtime error: %s\n", message);
    else fputs("hilbert: runtime error\n", stderr);
    abort();
}

/*
 * Stable POSIX adapters used by the first-party Hilbert modules.
 *
 * Applications should not have to reproduce libc's platform-dependent
 * dirent/stat layouts.  These functions deliberately expose only scalars,
 * pointers and the fixed-width record below, leaving traversal policy,
 * filtering, path construction and resource ownership in Hilbert.
 */

enum hilbert_posix_file_kind {
    HILBERT_POSIX_UNKNOWN = 0,
    HILBERT_POSIX_REGULAR = 1,
    HILBERT_POSIX_DIRECTORY = 2,
    HILBERT_POSIX_SYMLINK = 3,
    HILBERT_POSIX_OTHER = 4
};

enum hilbert_posix_file_flags {
    HILBERT_POSIX_EXECUTABLE = 1u << 0,
    HILBERT_POSIX_EMPTY = 1u << 1
};

struct hilbert_posix_file_info {
    uint64_t device;
    uint64_t inode;
    int64_t size;
    int64_t modified_seconds;
    int64_t modified_nanoseconds;
    uint32_t mode;
    uint32_t links;
    uint32_t user;
    uint32_t group;
    int32_t kind;
    uint32_t flags;
};

static int32_t hilbert_posix_kind(mode_t mode)
{
    if (S_ISREG(mode)) return HILBERT_POSIX_REGULAR;
    if (S_ISDIR(mode)) return HILBERT_POSIX_DIRECTORY;
    if (S_ISLNK(mode)) return HILBERT_POSIX_SYMLINK;
    return HILBERT_POSIX_OTHER;
}

static int32_t hilbert_posix_dirent_kind(unsigned char type)
{
    switch (type) {
    case DT_REG: return HILBERT_POSIX_REGULAR;
    case DT_DIR: return HILBERT_POSIX_DIRECTORY;
    case DT_LNK: return HILBERT_POSIX_SYMLINK;
    case DT_FIFO:
    case DT_SOCK:
    case DT_CHR:
    case DT_BLK: return HILBERT_POSIX_OTHER;
    default: return HILBERT_POSIX_UNKNOWN;
    }
}

static void hilbert_posix_fill_info(const struct stat *source,
                                    struct hilbert_posix_file_info *target)
{
    uint32_t flags = 0;
    memset(target, 0, sizeof(*target));
    target->device = (uint64_t)source->st_dev;
    target->inode = (uint64_t)source->st_ino;
    target->size = source->st_size;
    target->modified_seconds = source->st_mtim.tv_sec;
    target->modified_nanoseconds = source->st_mtim.tv_nsec;
    target->mode = (uint32_t)source->st_mode;
    target->links = (uint32_t)source->st_nlink;
    target->user = source->st_uid;
    target->group = source->st_gid;
    target->kind = hilbert_posix_kind(source->st_mode);
    if (S_ISREG(source->st_mode) && (source->st_mode & 0111) != 0) {
        flags |= HILBERT_POSIX_EXECUTABLE;
    }
    if (S_ISREG(source->st_mode) && source->st_size == 0) {
        flags |= HILBERT_POSIX_EMPTY;
    }
    target->flags = flags;
}

int32_t hilbert_rt_posix_dir_next(void *opaque, const char **name, int32_t *kind)
{
    DIR *directory = (DIR *)opaque;
    struct dirent *entry;
    if (name) *name = NULL;
    if (kind) *kind = HILBERT_POSIX_UNKNOWN;
    if (!directory || !name || !kind) {
        errno = EINVAL;
        return -1;
    }
    errno = 0;
    entry = readdir(directory);
    if (!entry) return errno == 0 ? 0 : -1;
    *name = entry->d_name;
    *kind = hilbert_posix_dirent_kind(entry->d_type);
    return 1;
}

int32_t hilbert_rt_posix_dir_descriptor(void *opaque)
{
    if (!opaque) {
        errno = EINVAL;
        return -1;
    }
    return dirfd((DIR *)opaque);
}

int32_t hilbert_rt_posix_stat(const char *path, int32_t follow,
                              struct hilbert_posix_file_info *target)
{
    struct stat value;
    int result;
    if (!path || !target) {
        errno = EINVAL;
        return -1;
    }
    result = follow ? stat(path, &value) : lstat(path, &value);
    if (result != 0) return -1;
    hilbert_posix_fill_info(&value, target);
    return 0;
}

int32_t hilbert_rt_posix_stat_at(void *opaque, const char *name, int32_t follow,
                                 struct hilbert_posix_file_info *target)
{
    struct stat value;
    int descriptor;
    int flags = follow ? 0 : AT_SYMLINK_NOFOLLOW;
    if (!opaque || !name || !target) {
        errno = EINVAL;
        return -1;
    }
    descriptor = dirfd((DIR *)opaque);
    if (descriptor < 0) return -1;
    if (fstatat(descriptor, name, &value, flags) != 0) return -1;
    hilbert_posix_fill_info(&value, target);
    return 0;
}

static int32_t hilbert_posix_directory_empty(DIR *directory)
{
    struct dirent *entry;
    int saved;
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            return 0;
        }
    }
    saved = errno;
    if (saved != 0) {
        errno = saved;
        return -1;
    }
    return 1;
}

int32_t hilbert_rt_posix_directory_empty(const char *path)
{
    DIR *directory;
    int32_t result;
    int saved;
    if (!path) {
        errno = EINVAL;
        return -1;
    }
    directory = opendir(path);
    if (!directory) return -1;
    result = hilbert_posix_directory_empty(directory);
    saved = errno;
    (void)closedir(directory);
    errno = saved;
    return result;
}

int32_t hilbert_rt_posix_directory_empty_at(void *opaque, const char *name)
{
    int parent_descriptor;
    int descriptor;
    DIR *directory;
    int32_t result;
    int saved;
    if (!opaque || !name) {
        errno = EINVAL;
        return -1;
    }
    parent_descriptor = dirfd((DIR *)opaque);
    if (parent_descriptor < 0) return -1;
    descriptor = openat(parent_descriptor, name,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) return -1;
    directory = fdopendir(descriptor);
    if (!directory) {
        saved = errno;
        (void)close(descriptor);
        errno = saved;
        return -1;
    }
    result = hilbert_posix_directory_empty(directory);
    saved = errno;
    (void)closedir(directory);
    errno = saved;
    return result;
}

extern char **environ;

int32_t hilbert_rt_posix_spawn(const char *const *arguments, size_t count)
{
    char **terminated;
    pid_t process;
    int result;
    size_t i;
    if (!arguments || count == 0 || !arguments[0]) {
        errno = EINVAL;
        return -1;
    }
    if (count > (size_t)INT32_MAX) {
        errno = E2BIG;
        return -1;
    }
    terminated = calloc(count + 1u, sizeof(*terminated));
    if (!terminated) return -1;
    for (i = 0; i < count; ++i) terminated[i] = (char *)arguments[i];
    result = posix_spawnp(&process, terminated[0], NULL, NULL, terminated, environ);
    free(terminated);
    if (result != 0) {
        errno = result;
        return -1;
    }
    if (process > INT32_MAX) {
        errno = EOVERFLOW;
        return -1;
    }
    return (int32_t)process;
}

int32_t hilbert_rt_posix_wait(int32_t process, int32_t *exit_status)
{
    int status;
    pid_t result;
    if (process <= 0 || !exit_status) {
        errno = EINVAL;
        return -1;
    }
    do {
        result = waitpid((pid_t)process, &status, 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0) return -1;
    if (WIFEXITED(status)) *exit_status = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) *exit_status = 128 + WTERMSIG(status);
    else *exit_status = 255;
    return 0;
}

const char *hilbert_rt_cstring_at(const char *text, size_t offset)
{
    if (!text) {
        errno = EINVAL;
        return NULL;
    }
    return text + offset;
}
