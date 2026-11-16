// Main-thread work queue. Modern AppKit traps when some calls come from other threads (the
// game's rendering thread calls -[NSOpenGLContext setView:]). The game's main thread runs the
// engine loop instead of the run loop, so work is drained at points the main thread reaches
// through the runtime: every message send, and every wait/sleep/lock in slices.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include <errno.h>
#include <sched.h>
#include <unistd.h>
#include "rt.h"

#define RET() (C.rsp += 8)

typedef struct Work { void (*fn)(void *); void *ctx; volatile int done; struct Work *next; } Work;
static Work *head, *tail;
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_done = PTHREAD_COND_INITIALIZER;
static pthread_cond_t q_work = PTHREAD_COND_INITIALIZER;   // signalled when work is queued
static volatile int pending;

void rt_main_drain(void) {
    if (!__atomic_load_n(&pending, __ATOMIC_ACQUIRE)) return;
    for (;;) {
        pthread_mutex_lock(&q_lock);
        Work *w = head;
        if (w) { head = w->next; if (!head) tail = 0; __atomic_sub_fetch(&pending, 1, __ATOMIC_RELEASE); }
        pthread_mutex_unlock(&q_lock);
        if (!w) return;
        w->fn(w->ctx);
        pthread_mutex_lock(&q_lock);
        w->done = 1;
        pthread_cond_broadcast(&q_done);
        pthread_mutex_unlock(&q_lock);
    }
}

static void drain_from_runloop(void *unused) { (void)unused; rt_main_drain(); }

void rt_main_sync(void (*fn)(void *), void *ctx) {
    if (pthread_main_np()) { fn(ctx); return; }
    Work w = {fn, ctx, 0, 0};
    pthread_mutex_lock(&q_lock);
    if (tail) tail->next = &w; else head = &w;
    tail = &w;
    __atomic_add_fetch(&pending, 1, __ATOMIC_RELEASE);
    pthread_cond_signal(&q_work);
    pthread_mutex_unlock(&q_lock);
    dispatch_async_f(dispatch_get_main_queue(), 0, drain_from_runloop);   // if main is in a native run loop
    pthread_mutex_lock(&q_lock);
    while (!w.done) pthread_cond_wait(&q_done, &q_lock);
    pthread_mutex_unlock(&q_lock);
}

// does sending `sel` to `recv` have to happen on the main thread?
int rt_needs_main(id recv, SEL sel) {
    static Class cView, cWindow, cApp, cCursor, cGL;
    static SEL sSetView, sUpdate, sClear, sFull;
    if (!cView) {
        cView = objc_getClass("NSView"); cWindow = objc_getClass("NSWindow"); cApp = objc_getClass("NSApplication");
        cCursor = objc_getClass("NSCursor"); cGL = objc_getClass("NSOpenGLContext");
        sSetView = sel_registerName("setView:"); sUpdate = sel_registerName("update");
        sClear = sel_registerName("clearDrawable"); sFull = sel_registerName("setFullScreen");
    }
    for (Class k = object_getClass(recv); k; k = class_getSuperclass(k)) {
        if (k == cGL) return sel == sSetView || sel == sUpdate || sel == sClear || sel == sFull;
        if (k == cView || k == cWindow || k == cApp || k == cCursor) return 1;
    }
    return 0;
}

// ---------- blocking primitives: the main thread waits in slices and drains between them ----------
static struct timespec deadline_in(long ns) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    t.tv_nsec += ns;
    t.tv_sec += t.tv_nsec / 1000000000; t.tv_nsec %= 1000000000;
    return t;
}
static int before(const struct timespec *a, const struct timespec *b) {
    return a->tv_sec < b->tv_sec || (a->tv_sec == b->tv_sec && a->tv_nsec < b->tv_nsec);
}

// Every guest signal/broadcast bumps a per-condition-variable counter before signalling. The main
// thread waits in slices (to service AppKit work) and uses the counter to tell a real signal from
// a timed-out slice: a broadcast racing a slice's timeout is otherwise lost, and PhysX's NxSync
// waits exactly once without re-checking its flag. Keyed by exact address (no false wakeups).
// Only main-thread waits create entries (a small, stable set); signals just bump existing ones.
// The waiter registers and reads the counter while holding the mutex, so a signal sent under that
// mutex cannot fall between registration and the wait.
#define NGEN 4096
static struct { pthread_cond_t *cv; volatile uint32_t gen; } gens[NGEN];
static os_unfair_lock gen_lock = OS_UNFAIR_LOCK_INIT;

static volatile uint32_t *cond_gen(pthread_cond_t *cv, int create) {
    uint64_t h = ((uint64_t)cv >> 4) * 0x9E3779B97F4A7C15ull;
    for (uint64_t k = h % NGEN, n = 0; n < NGEN; k = (k + 1) % NGEN, n++) {
        pthread_cond_t *have = __atomic_load_n(&gens[k].cv, __ATOMIC_ACQUIRE);
        if (have == cv) return &gens[k].gen;
        if (!have && !create) return 0;
        if (!have) {
            os_unfair_lock_lock(&gen_lock);
            if (!gens[k].cv) __atomic_store_n(&gens[k].cv, cv, __ATOMIC_RELEASE);
            os_unfair_lock_unlock(&gen_lock);
            if (gens[k].cv == cv) return &gens[k].gen;
        }
    }
    fprintf(stderr, "mainq: condition variable table full\n");
    abort();
}

void I__pthread_cond_signal(CPU *c) {
    pthread_cond_t *cv = (pthread_cond_t *)C.rdi;
    volatile uint32_t *g = cond_gen(cv, 0);
    if (g) __atomic_add_fetch(g, 1, __ATOMIC_SEQ_CST);
    C.rax = (uint32_t)pthread_cond_signal(cv); RET();
}
void I__pthread_cond_broadcast(CPU *c) {
    pthread_cond_t *cv = (pthread_cond_t *)C.rdi;
    volatile uint32_t *g = cond_gen(cv, 0);
    if (g) __atomic_add_fetch(g, 1, __ATOMIC_SEQ_CST);
    C.rax = (uint32_t)pthread_cond_broadcast(cv); RET();
}

void I__pthread_cond_wait(CPU *c) {
    pthread_cond_t *cv = (pthread_cond_t *)C.rdi; pthread_mutex_t *m = (pthread_mutex_t *)C.rsi;
    if (!pthread_main_np()) { C.rax = (uint32_t)pthread_cond_wait(cv, m); RET(); return; }
    volatile uint32_t *gen = cond_gen(cv, 1);
    uint32_t g0 = __atomic_load_n(gen, __ATOMIC_SEQ_CST);
    int r;
    for (;;) {
        struct timespec t = deadline_in(2000000);
        r = pthread_cond_timedwait(cv, m, &t);
        if (r != ETIMEDOUT || __atomic_load_n(gen, __ATOMIC_SEQ_CST) != g0) { r = 0; break; }
        rt_main_drain();                     // mutex held, so no signal can slip between slices
    }
    C.rax = (uint32_t)r; RET();
}

void I__pthread_cond_timedwait(CPU *c) {
    pthread_cond_t *cv = (pthread_cond_t *)C.rdi; pthread_mutex_t *m = (pthread_mutex_t *)C.rsi;
    const struct timespec *abs = (const struct timespec *)C.rdx;
    if (!pthread_main_np()) { C.rax = (uint32_t)pthread_cond_timedwait(cv, m, abs); RET(); return; }
    volatile uint32_t *gen = cond_gen(cv, 1);
    uint32_t g0 = __atomic_load_n(gen, __ATOMIC_SEQ_CST);
    int r;
    for (;;) {
        struct timespec slice = deadline_in(2000000);
        r = pthread_cond_timedwait(cv, m, before(abs, &slice) ? abs : &slice);
        if (r != ETIMEDOUT || __atomic_load_n(gen, __ATOMIC_SEQ_CST) != g0) { r = 0; break; }
        struct timespec now = deadline_in(0);
        if (!before(&now, abs)) break;       // real timeout
        rt_main_drain();
    }
    C.rax = (uint32_t)r; RET();
}

void I__pthread_mutex_lock(CPU *c) {
    pthread_mutex_t *m = (pthread_mutex_t *)C.rdi;
    if (!pthread_main_np()) { C.rax = (uint32_t)pthread_mutex_lock(m); RET(); return; }
    int r;
    while ((r = pthread_mutex_trylock(m)) == EBUSY) { rt_main_drain(); sched_yield(); }
    C.rax = (uint32_t)r; RET();
}

// the game's frame limiter sleeps here: sleep the whole interval in one timed wait (slices oversleep
// and drag UE3's smoothed frame cap down), waking early only to run queued main-thread work
void I__usleep(CPU *c) {
    useconds_t us = (useconds_t)C.rdi;
    if (!pthread_main_np()) { C.rax = (uint32_t)usleep(us); RET(); return; }
    struct timespec end = deadline_in((long)us * 1000);
    for (;;) {
        rt_main_drain();
        pthread_mutex_lock(&q_lock);
        int r = 0;
        while (!pending && r != ETIMEDOUT) r = pthread_cond_timedwait(&q_work, &q_lock, &end);
        pthread_mutex_unlock(&q_lock);
        if (r == ETIMEDOUT) break;
    }
    rt_main_drain();
    C.rax = 0; RET();
}

void I__sched_yield(CPU *c) {
    if (pthread_main_np()) rt_main_drain();
    C.rax = (uint32_t)sched_yield(); RET();
}
