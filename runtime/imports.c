// Host thunks for imported functions. A thunk reads System V x86_64 arguments from the guest
// CPU, calls the native arm64 function, writes the result back, and pops the guest return address.
// Data layouts match between x86_64 and arm64 macOS, so pointers and structs pass through as is.
#include "rt.h"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <pthread.h>
#include <libkern/OSAtomic.h>
#include <mach/mach_time.h>
#include <zlib.h>
#include <malloc/malloc.h>
#include <time.h>

typedef uint64_t (*int6)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
#define RET() (C.rsp += 8)

// integer/pointer-only signature: up to six register arguments, result in rax
#define INT_THUNK(name) void I__##name(CPU *c) { \
    C.rax = ((int6)(void *)name)(C.rdi, C.rsi, C.rdx, C.rcx, C.r8, C.r9); RET(); }
#define F1_THUNK(name) void I__##name(CPU *c) { C.xmm[0].f[0] = name(C.xmm[0].f[0]); RET(); }
#define F2_THUNK(name) void I__##name(CPU *c) { C.xmm[0].f[0] = name(C.xmm[0].f[0], C.xmm[1].f[0]); RET(); }

INT_THUNK(memcpy) INT_THUNK(memmove) INT_THUNK(memset) INT_THUNK(memcmp)
INT_THUNK(strlen) INT_THUNK(strcmp) INT_THUNK(strncmp) INT_THUNK(strcpy) INT_THUNK(strncpy) INT_THUNK(strchr) INT_THUNK(strstr)
INT_THUNK(wcslen) INT_THUNK(wcscmp) INT_THUNK(wcsncmp) INT_THUNK(wcscpy) INT_THUNK(wcsncpy) INT_THUNK(wcschr) INT_THUNK(wcsstr)
INT_THUNK(wcsrchr) INT_THUNK(wcscat) INT_THUNK(wcstoul) INT_THUNK(wcstol) INT_THUNK(towupper) INT_THUNK(towlower)
INT_THUNK(malloc) INT_THUNK(calloc) INT_THUNK(realloc) INT_THUNK(free) INT_THUNK(posix_memalign)
INT_THUNK(pthread_mutex_init) INT_THUNK(pthread_mutex_unlock) INT_THUNK(pthread_mutex_destroy)
INT_THUNK(pthread_mutexattr_init) INT_THUNK(pthread_mutexattr_settype) INT_THUNK(pthread_mutexattr_destroy)
INT_THUNK(pthread_self) INT_THUNK(pthread_getspecific) INT_THUNK(pthread_setspecific)
INT_THUNK(OSAtomicIncrement32Barrier) INT_THUNK(OSAtomicDecrement32Barrier) INT_THUNK(OSAtomicAdd32Barrier)
INT_THUNK(OSAtomicCompareAndSwap32Barrier) INT_THUNK(OSAtomicCompareAndSwapPtrBarrier) INT_THUNK(OSAtomicCompareAndSwap64Barrier)
INT_THUNK(OSAtomicAdd64Barrier) INT_THUNK(OSAtomicIncrement64Barrier) INT_THUNK(OSAtomicDecrement64Barrier)
INT_THUNK(mach_absolute_time) INT_THUNK(mach_timebase_info) INT_THUNK(rand) INT_THUNK(srand) INT_THUNK(time)
INT_THUNK(strcasecmp) INT_THUNK(strncasecmp) INT_THUNK(memset_pattern16) INT_THUNK(pthread_mach_thread_np)
INT_THUNK(compress) INT_THUNK(uncompress) INT_THUNK(getenv) INT_THUNK(abs)
F1_THUNK(floorf) F1_THUNK(ceilf) F1_THUNK(roundf) F1_THUNK(sinf) F1_THUNK(cosf) F1_THUNK(tanf) F1_THUNK(acosf)
F1_THUNK(asinf) F1_THUNK(atanf) F1_THUNK(expf) F1_THUNK(logf) F1_THUNK(log10f) F1_THUNK(fabsf) F1_THUNK(truncf)
F2_THUNK(powf) F2_THUNK(atan2f) F2_THUNK(fmodf)

// renamed or ABI-specific
void I____bzero(CPU *c) { memset((void *)C.rdi, 0, C.rsi); RET(); }
void I____sincosf_stret(CPU *c) { float x = C.xmm[0].f[0]; C.xmm[0].f[0] = sinf(x); C.xmm[0].f[1] = cosf(x); RET(); }
void I____stack_chk_fail(CPU *c) { unimpl_import(c, "__stack_chk_fail (guest stack smashed)"); }
void I____cxa_guard_acquire(CPU *c) { extern int __cxa_guard_acquire(uint64_t *); C.rax = __cxa_guard_acquire((uint64_t *)C.rdi); RET(); }
void I____cxa_guard_release(CPU *c) { extern void __cxa_guard_release(uint64_t *); __cxa_guard_release((uint64_t *)C.rdi); RET(); }
void I___Znwm(CPU *c) { C.rax = (uint64_t)malloc(C.rdi); RET(); }
void I___Znam(CPU *c) { C.rax = (uint64_t)malloc(C.rdi); RET(); }
void I___ZdlPv(CPU *c) { free((void *)C.rdi); RET(); }
void I___ZdaPv(CPU *c) { free((void *)C.rdi); RET(); }

// static destructors: guest callbacks; recorded and run by the runtime at exit (not yet)
typedef struct { uint64_t fn, arg; } AtExit;
static AtExit atexit_list[4096];
int rt_natexit;
void I____cxa_atexit(CPU *c) {
    if (rt_natexit < 4096) atexit_list[rt_natexit++] = (AtExit){C.rdi, C.rsi};
    C.rax = 0; RET();
}
