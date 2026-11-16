// Runtime for statically recompiled x86_64 code.
// The guest image is mapped at a fixed host base and rebased, so guest pointers are host
// pointers and memory is accessed directly. G(a) turns a link-time guest address into its
// host address. Every translated function receives `CPU *c` (one per guest thread);
// inside them `C` names the current CPU.
#pragma once
#include <stdint.h>
#include <string.h>
#include <math.h>

#define GUEST_LINK_BASE 0x100000000ull
#define GUEST_HOST_BASE 0x300000000000ull
#define GSLIDE (GUEST_HOST_BASE - GUEST_LINK_BASE)
#define G(a) ((uint64_t)(a) + GSLIDE)

typedef union {
    float f[4];
    double d[2];
    uint32_t u[4];
    int32_t i[4];
    uint64_t q[2];
    int64_t sq[2];
    uint16_t w[8];
    int16_t sw[8];
    uint8_t b[16];
} XMM;

typedef struct CPU {
    uint64_t rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi;
    uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
    XMM xmm[16];
    uint32_t mxcsr;
    uint8_t x87raw[8][10];   // x87 stack, raw 80-bit values (only ever copied)
    int x87top;
    uint64_t stack_lo, stack_hi;
    uint64_t fn;    // guest function currently executing (debug)
} CPU;

typedef void (*gfn)(CPU *c);
typedef struct { uint64_t addr; gfn fn; } GFunc;

#ifndef NO_TRACE
#define TRACE_FN(a) (c->fn = (a))
#else
#define TRACE_FN(a) ((void)0)
#endif
#define C (*c)

// Guest memory. x86 is TSO: loads are not reordered with loads and stores not with stores.
// Shared-memory accesses therefore use load-acquire / store-release (LDAPR / STLR). With LSE2
// these allow unaligned addresses within a 16-byte granule; accesses crossing one fall back to a
// plain access plus a fence. Thread-private stack accesses (rsp/rbp based) use the plain *s forms.
#ifdef RT_NO_TSO      /* measurement only: plain accesses, x86 ordering NOT preserved */
#define CROSSES(a, n) 1
#define __atomic_thread_fence(x) ((void)0)
#else
#define CROSSES(a, n) ((((a) & 15) + (n)) > 16)
#endif
#define ORD_LOAD(T, a) do { T v_; if (__builtin_expect(!CROSSES(a, sizeof(T)), 1)) return __atomic_load_n((T *)(a), __ATOMIC_ACQUIRE); \
    memcpy(&v_, (void *)(a), sizeof(T)); __atomic_thread_fence(__ATOMIC_ACQUIRE); return v_; } while (0)
#define ORD_STORE(T, a, v) do { if (__builtin_expect(!CROSSES(a, sizeof(T)), 1)) { __atomic_store_n((T *)(a), (v), __ATOMIC_RELEASE); return; } \
    __atomic_thread_fence(__ATOMIC_RELEASE); T v_ = (v); memcpy((void *)(a), &v_, sizeof(T)); } while (0)

#ifdef RT_NO_TSO
static inline uint8_t  rd8 (uint64_t a) { return *(volatile uint8_t *)a; }
#else
static inline uint8_t  rd8 (uint64_t a) { return __atomic_load_n((uint8_t *)a, __ATOMIC_ACQUIRE); }
#endif
static inline uint16_t rd16(uint64_t a) { ORD_LOAD(uint16_t, a); }
static inline uint32_t rd32(uint64_t a) { ORD_LOAD(uint32_t, a); }
static inline uint64_t rd64(uint64_t a) { ORD_LOAD(uint64_t, a); }
static inline float    rdf (uint64_t a) { uint32_t u = rd32(a); float v; memcpy(&v, &u, 4); return v; }
static inline double   rdd (uint64_t a) { uint64_t u = rd64(a); double v; memcpy(&v, &u, 8); return v; }
static inline XMM      rdx (uint64_t a) { XMM v; memcpy(&v, (void *)a, 16); __atomic_thread_fence(__ATOMIC_ACQUIRE); return v; }
#ifdef RT_NO_TSO
static inline void wr8 (uint64_t a, uint8_t v)  { *(volatile uint8_t *)a = v; }
#else
static inline void wr8 (uint64_t a, uint8_t v)  { __atomic_store_n((uint8_t *)a, v, __ATOMIC_RELEASE); }
#endif
static inline void wr16(uint64_t a, uint16_t v) { ORD_STORE(uint16_t, a, v); }
static inline void wr32(uint64_t a, uint32_t v) { ORD_STORE(uint32_t, a, v); }
static inline void wr64(uint64_t a, uint64_t v) { ORD_STORE(uint64_t, a, v); }
static inline void wrf (uint64_t a, float v)    { uint32_t u; memcpy(&u, &v, 4); wr32(a, u); }
static inline void wrd (uint64_t a, double v)   { uint64_t u; memcpy(&u, &v, 8); wr64(a, u); }
static inline void wrx (uint64_t a, XMM v)      { __atomic_thread_fence(__ATOMIC_RELEASE); memcpy((void *)a, &v, 16); }

// thread-private (stack) accesses
static inline uint8_t  rd8s (uint64_t a) { return *(uint8_t *)a; }
static inline uint16_t rd16s(uint64_t a) { uint16_t v; memcpy(&v, (void *)a, 2); return v; }
static inline uint32_t rd32s(uint64_t a) { uint32_t v; memcpy(&v, (void *)a, 4); return v; }
static inline uint64_t rd64s(uint64_t a) { uint64_t v; memcpy(&v, (void *)a, 8); return v; }
static inline float    rdfs (uint64_t a) { float v;    memcpy(&v, (void *)a, 4); return v; }
static inline double   rdds (uint64_t a) { double v;   memcpy(&v, (void *)a, 8); return v; }
static inline XMM      rdxs (uint64_t a) { XMM v;      memcpy(&v, (void *)a, 16); return v; }
static inline void wr8s (uint64_t a, uint8_t v)  { *(uint8_t *)a = v; }
static inline void wr16s(uint64_t a, uint16_t v) { memcpy((void *)a, &v, 2); }
static inline void wr32s(uint64_t a, uint32_t v) { memcpy((void *)a, &v, 4); }
static inline void wr64s(uint64_t a, uint64_t v) { memcpy((void *)a, &v, 8); }
static inline void wrfs (uint64_t a, float v)    { memcpy((void *)a, &v, 4); }
static inline void wrds (uint64_t a, double v)   { memcpy((void *)a, &v, 8); }
static inline void wrxs (uint64_t a, XMM v)      { memcpy((void *)a, &v, 16); }

#define PUSH(v) do { uint64_t v_ = (v); C.rsp -= 8; wr64s(C.rsp, v_); } while (0)
#define POP() (C.rsp += 8, rd64s(C.rsp - 8))
// forms used by register-cached functions (tools/recomp.py cache_regs), where rsp is the local R_rsp
#define LPUSH(v) do { uint64_t v_ = (v); R_rsp -= 8; wr64s(R_rsp, v_); } while (0)
#define LPOP() (R_rsp += 8, rd64s(R_rsp - 8))
#define PARITY(r) (!__builtin_parity((uint32_t)((r) & 0xFF)))

// dispatch and failure paths (rt.c)
void call_ind(CPU *c, uint64_t target);
void missing_func(CPU *c, uint64_t target);
void missing_import(CPU *c);
void unimpl_import(CPU *c, const char *name);
void bad_insn(CPU *c, uint64_t guest_addr);
void bad_jump(CPU *c, uint64_t target, uint64_t guest_addr);
// guest setjmp/longjmp: the guest jmp_buf holds a pointer to host state (rt.c)
#include <setjmp.h>
typedef struct { jmp_buf host; uint64_t rbx, rbp, rsp, r12, r13, r14, r15; int val; } RtJmp;
RtJmp *rt_jmp_slot(CPU *c, uint64_t guest_jmp_buf);
static inline void rt_jmp_save(CPU *c, RtJmp *j) {
    j->rbx = C.rbx; j->rbp = C.rbp; j->rsp = C.rsp; j->r12 = C.r12; j->r13 = C.r13; j->r14 = C.r14; j->r15 = C.r15;
}
static inline void rt_jmp_restore(CPU *c, RtJmp *j) {
    C.rbx = j->rbx; C.rbp = j->rbp; C.rsp = j->rsp; C.r12 = j->r12; C.r13 = j->r13; C.r14 = j->r14; C.r15 = j->r15;
    C.rax = (uint32_t)j->val;
}
void rt_cpuid(CPU *c);
// Metal renderer (mgl.m): RT_METAL=1 routes every GL call to mgl_<name>
extern int rt_metal;
void mgl_init(void);
void mgl_set_view(void *view);
void mgl_present(void);
void mgl_set_swap_interval(int n);
double mgl_view_scale(void);
int mgl_game_fullscreen(void);
void mgl_pool_yield(void);
void *rt_screen(void);
int rt_screen_chosen(void);
void mgl_center_window(void *w);
void rt_main_sync(void (*fn)(void *), void *ctx);
// RT_GLCOUNT diagnostics (glcount.c)
extern int rt_glcount_on;
void rt_glcount_hit(int *slot, const char *name);
void rt_glcount_frame(void);
extern int rt_glargs_on;
void rt_glargs(const char *name, const uint64_t *a, int n, const double *f, int nf);
#define GLCOUNT(name) do { static int s_ = -1; if (rt_glcount_on) rt_glcount_hit(&s_, name); } while (0)
static inline uint64_t rt_rdtsc(void) { uint64_t t; __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t)); return t; }

// x86 float->int conversions: NaN / out of range give the "integer indefinite" value
static inline int32_t cvtt_i32(double v) { return (v != v || v >= 2147483648.0 || v < -2147483648.0) ? INT32_MIN : (int32_t)v; }
static inline int64_t cvtt_i64(double v) { return (v != v || v >= 9223372036854775808.0 || v < -9223372036854775808.0) ? INT64_MIN : (int64_t)v; }
static inline int32_t cvtr_i32(double v) { return cvtt_i32(nearbyint(v)); }
static inline int64_t cvtr_i64(double v) { return cvtt_i64(nearbyint(v)); }

// ---------- SSE helpers ----------
static inline XMM xmm_lo64(uint64_t q) { XMM x = {0}; x.q[0] = q; return x; }
static inline uint32_t xmm_movmskps(XMM a) { return (a.u[0] >> 31) | ((a.u[1] >> 31) << 1) | ((a.u[2] >> 31) << 2) | ((a.u[3] >> 31) << 3); }
static inline XMM xmm_shufps(XMM a, XMM b, int i) { XMM r; r.u[0] = a.u[i & 3]; r.u[1] = a.u[(i >> 2) & 3]; r.u[2] = b.u[(i >> 4) & 3]; r.u[3] = b.u[(i >> 6) & 3]; return r; }
static inline XMM xmm_shufpd(XMM a, XMM b, int i) { XMM r; r.q[0] = a.q[i & 1]; r.q[1] = b.q[(i >> 1) & 1]; return r; }
static inline XMM xmm_pshufd(XMM a, XMM b, int i) { (void)a; XMM r; for (int k = 0; k < 4; k++) r.u[k] = b.u[(i >> (2 * k)) & 3]; return r; }
static inline XMM xmm_unpcklps(XMM a, XMM b) { XMM r; r.u[0] = a.u[0]; r.u[1] = b.u[0]; r.u[2] = a.u[1]; r.u[3] = b.u[1]; return r; }
static inline XMM xmm_unpckhps(XMM a, XMM b) { XMM r; r.u[0] = a.u[2]; r.u[1] = b.u[2]; r.u[2] = a.u[3]; r.u[3] = b.u[3]; return r; }
static inline XMM xmm_unpcklpd(XMM a, XMM b) { XMM r; r.q[0] = a.q[0]; r.q[1] = b.q[0]; return r; }
static inline XMM xmm_unpckhpd(XMM a, XMM b) { XMM r; r.q[0] = a.q[1]; r.q[1] = b.q[1]; return r; }
#define xmm_punpckldq xmm_unpcklps
#define xmm_punpcklqdq xmm_unpcklpd
#define xmm_punpckhqdq xmm_unpckhpd
static inline XMM xmm_punpcklwd(XMM a, XMM b) { XMM r; for (int k = 0; k < 4; k++) { r.w[2 * k] = a.w[k]; r.w[2 * k + 1] = b.w[k]; } return r; }
static inline XMM xmm_punpcklbw(XMM a, XMM b) { XMM r; for (int k = 0; k < 8; k++) { r.b[2 * k] = a.b[k]; r.b[2 * k + 1] = b.b[k]; } return r; }
static inline XMM xmm_movshdup(XMM a, XMM b) { (void)a; XMM r; r.u[0] = r.u[1] = b.u[1]; r.u[2] = r.u[3] = b.u[3]; return r; }
static inline XMM xmm_movsldup(XMM a, XMM b) { (void)a; XMM r; r.u[0] = r.u[1] = b.u[0]; r.u[2] = r.u[3] = b.u[2]; return r; }
static inline XMM xmm_movddup(XMM a, XMM b) { (void)a; XMM r; r.q[0] = r.q[1] = b.q[0]; return r; }
static inline XMM xmm_haddps(XMM a, XMM b) { XMM r; r.f[0] = a.f[0] + a.f[1]; r.f[1] = a.f[2] + a.f[3]; r.f[2] = b.f[0] + b.f[1]; r.f[3] = b.f[2] + b.f[3]; return r; }
static inline XMM xmm_haddpd(XMM a, XMM b) { XMM r; r.d[0] = a.d[0] + a.d[1]; r.d[1] = b.d[0] + b.d[1]; return r; }
static inline XMM xmm_addsubps(XMM a, XMM b) { XMM r; r.f[0] = a.f[0] - b.f[0]; r.f[1] = a.f[1] + b.f[1]; r.f[2] = a.f[2] - b.f[2]; r.f[3] = a.f[3] + b.f[3]; return r; }
static inline XMM xmm_pshufb(XMM a, XMM b) { XMM r; for (int k = 0; k < 16; k++) r.b[k] = (b.b[k] & 0x80) ? 0 : a.b[b.b[k] & 15]; return r; }
static inline XMM xmm_phaddd(XMM a, XMM b) { XMM r; r.u[0] = a.u[0] + a.u[1]; r.u[1] = a.u[2] + a.u[3]; r.u[2] = b.u[0] + b.u[1]; r.u[3] = b.u[2] + b.u[3]; return r; }
static inline XMM xmm_pmuludq(XMM a, XMM b) { XMM r; r.q[0] = (uint64_t)a.u[0] * b.u[0]; r.q[1] = (uint64_t)a.u[2] * b.u[2]; return r; }
static inline int16_t sat16(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }
static inline uint8_t satu8(int16_t v) { return v > 255 ? 255 : v < 0 ? 0 : (uint8_t)v; }
static inline XMM xmm_packssdw(XMM a, XMM b) { XMM r; for (int k = 0; k < 4; k++) { r.sw[k] = sat16(a.i[k]); r.sw[k + 4] = sat16(b.i[k]); } return r; }
static inline XMM xmm_packuswb(XMM a, XMM b) { XMM r; for (int k = 0; k < 8; k++) { r.b[k] = satu8(a.sw[k]); r.b[k + 8] = satu8(b.sw[k]); } return r; }
static inline XMM xmm_pcmpeqd(XMM a, XMM b) { XMM r; for (int k = 0; k < 4; k++) r.u[k] = a.u[k] == b.u[k] ? ~0u : 0; return r; }
static inline XMM xmm_pcmpgtd(XMM a, XMM b) { XMM r; for (int k = 0; k < 4; k++) r.u[k] = a.i[k] > b.i[k] ? ~0u : 0; return r; }
static inline XMM xmm_paddd(XMM a, XMM b) { for (int k = 0; k < 4; k++) a.u[k] += b.u[k]; return a; }
static inline XMM xmm_paddq(XMM a, XMM b) { for (int k = 0; k < 2; k++) a.q[k] += b.q[k]; return a; }
static inline XMM xmm_paddw(XMM a, XMM b) { for (int k = 0; k < 8; k++) a.w[k] += b.w[k]; return a; }
static inline XMM xmm_psubd(XMM a, XMM b) { for (int k = 0; k < 4; k++) a.u[k] -= b.u[k]; return a; }
static inline XMM xmm_psubq(XMM a, XMM b) { for (int k = 0; k < 2; k++) a.q[k] -= b.q[k]; return a; }
static inline XMM xmm_pslld(XMM a, int n) { for (int k = 0; k < 4; k++) a.u[k] = n > 31 ? 0 : a.u[k] << n; return a; }
static inline XMM xmm_psrld(XMM a, int n) { for (int k = 0; k < 4; k++) a.u[k] = n > 31 ? 0 : a.u[k] >> n; return a; }
static inline XMM xmm_psrad(XMM a, int n) { for (int k = 0; k < 4; k++) a.i[k] = a.i[k] >> (n > 31 ? 31 : n); return a; }
static inline XMM xmm_psllq(XMM a, int n) { for (int k = 0; k < 2; k++) a.q[k] = n > 63 ? 0 : a.q[k] << n; return a; }
static inline XMM xmm_psrlq(XMM a, int n) { for (int k = 0; k < 2; k++) a.q[k] = n > 63 ? 0 : a.q[k] >> n; return a; }
static inline XMM xmm_pslldq(XMM a, int n) { XMM r = {0}; if (n < 16) for (int k = n; k < 16; k++) r.b[k] = a.b[k - n]; return r; }
static inline XMM xmm_psrldq(XMM a, int n) { XMM r = {0}; if (n < 16) for (int k = 0; k + n < 16; k++) r.b[k] = a.b[k + n]; return r; }
