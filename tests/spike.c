// Feasibility checks: run translated game code natively and compare against host references.
#include "rt.h"
#include "image.h"
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <zlib.h>

extern sigjmp_buf *rt_trap;
extern const char *rt_last_failure;
extern int rt_natexit;

static CPU *cpu;
static sigjmp_buf trap;

static void on_signal(int sig, siginfo_t *si, void *uc) {
    (void)uc;
    static char b[160];
    snprintf(b, sizeof b, "signal %d at address %p (in guest fn 0x%llx)", sig, si->si_addr, (unsigned long long)cpu->fn);
    rt_last_failure = b;
    siglongjmp(trap, 1);
}

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

// call a guest function with integer args; returns rax, or reports failure
static int guest(uint64_t fn, uint64_t *ret, int n, ...) {
    __builtin_va_list ap; __builtin_va_start(ap, n);
    uint64_t *regs[] = {&cpu->rdi, &cpu->rsi, &cpu->rdx, &cpu->rcx, &cpu->r8, &cpu->r9};
    for (int k = 0; k < n; k++) *regs[k] = __builtin_va_arg(ap, uint64_t);
    __builtin_va_end(ap);
    uint64_t sp = cpu->rsp;
    if (sigsetjmp(trap, 1)) { cpu->rsp = sp; return 0; }
    rt_trap = &trap;
    rt_call(cpu, fn);
    rt_trap = 0;
    if (cpu->rsp != sp) { rt_last_failure = "stack imbalance"; cpu->rsp = sp; return 0; }
    if (ret) *ret = cpu->rax;
    return 1;
}

static int pass, total;
static void check(const char *what, int ok, const char *detail) {
    total++; pass += ok;
    printf("[%s] %s%s%s\n", ok ? "PASS" : "FAIL", what, detail ? " - " : "", detail ? detail : "");
}

// ---------- ABI bridge checks: simulate guest call sites against real Cocoa ----------
#include <objc/runtime.h>
#include <objc/message.h>
#include "abi.h"
void I__objc_msgSend(CPU *c);
void I__objc_msgSend_stret(CPU *c);
void rt_objc_init(void);
typedef struct { double x, y, w, h; } Rect4;

static void guest_calls_thunk(void (*thunk)(CPU *), uint64_t *stack_args, int n) {
    // lay out a System V call: stack arguments above the return address
    uint64_t sp = (cpu->rsp - 8 * n - 64) & ~15ull;
    for (int k = 0; k < n; k++) wr64(sp + 8 * k, stack_args[k]);
    uint64_t saved = cpu->rsp;
    cpu->rsp = sp - 8;               // the call pushed a return address
    thunk(cpu);
    if (cpu->rsp != sp) printf("       (thunk left rsp off by %lld)\n", (long long)(cpu->rsp - sp));
    cpu->rsp = saved;
}

static void abi_checks(void) {
    char msg[256];
    id NSValue_ = (id)objc_getClass("NSValue");
    // valueWithRect: takes a 32-byte struct -> passed in memory on the guest stack
    Rect4 r = {1.5, -2.25, 640, 480};
    cpu->rdi = (uint64_t)NSValue_; cpu->rsi = (uint64_t)sel_registerName("valueWithRect:");
    guest_calls_thunk(I__objc_msgSend, (uint64_t *)&r, 4);
    id v = (id)cpu->rax;
    // rectValue returns it through objc_msgSend_stret (rdi = result buffer)
    Rect4 back = {0};
    cpu->rdi = (uint64_t)&back; cpu->rsi = (uint64_t)v; cpu->rdx = (uint64_t)sel_registerName("rectValue");
    guest_calls_thunk(I__objc_msgSend_stret, 0, 0);
    snprintf(msg, sizeof msg, "{%g %g %g %g} -> {%g %g %g %g}", r.x, r.y, r.w, r.h, back.x, back.y, back.w, back.h);
    check("msgSend NSRect in memory + stret return", !memcmp(&r, &back, sizeof r) && cpu->rax == (uint64_t)&back, msg);

    // valueWithPoint: takes {double,double} -> xmm0, xmm1; pointValue returns in xmm0, xmm1
    cpu->rdi = (uint64_t)NSValue_; cpu->rsi = (uint64_t)sel_registerName("valueWithPoint:");
    cpu->xmm[0].d[0] = 3.5; cpu->xmm[1].d[0] = 7.25;
    guest_calls_thunk(I__objc_msgSend, 0, 0);
    cpu->rdi = cpu->rax; cpu->rsi = (uint64_t)sel_registerName("pointValue");
    cpu->xmm[0].d[0] = cpu->xmm[1].d[0] = 0;
    guest_calls_thunk(I__objc_msgSend, 0, 0);
    snprintf(msg, sizeof msg, "(3.5, 7.25) -> (%g, %g)", cpu->xmm[0].d[0], cpu->xmm[1].d[0]);
    check("msgSend NSPoint in SSE registers both ways", cpu->xmm[0].d[0] == 3.5 && cpu->xmm[1].d[0] == 7.25, msg);

    // stringWithFormat: is variadic: int in rcx, double in xmm0, C string in r8
    cpu->rdi = (uint64_t)objc_getClass("NSString"); cpu->rsi = (uint64_t)sel_registerName("stringWithFormat:");
    cpu->rdx = (uint64_t)((id (*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), "%d|%.2f|%s");
    cpu->rcx = (uint64_t)-42; cpu->xmm[0].d[0] = 3.14159; cpu->r8 = (uint64_t)"ok";
    guest_calls_thunk(I__objc_msgSend, 0, 0);
    const char *s = ((const char *(*)(id, SEL))objc_msgSend)((id)cpu->rax, sel_registerName("UTF8String"));
    check("stringWithFormat: variadic marshalling", s && !strcmp(s, "-42|3.14|ok"), s);

    // native -> guest closure: call the game's FMatrix::Inverse through a host function pointer
    Sig *sg = sig_parse("v^v^v");
    void (*inv)(float *, const float *) = sig_closure(sg, 0x100435fa0);
    float M[16] = {1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 4, 0, 1, 2, 3, 1}, I[16] = {0};
    inv(I, M);
    snprintf(msg, sizeof msg, "diag %g %g %g, translation %g %g %g", I[0], I[5], I[10], I[12], I[13], I[14]);
    check("native->guest closure", I[0] == 1 && I[5] == 0.5f && I[10] == 0.25f && I[12] == -1 && I[13] == -1 && I[14] == -0.75f, msg);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s ShadowComplexRemastered-binary\n", argv[0]); return 2; }
    struct sigaction sa = {0};
    sa.sa_sigaction = on_signal; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    stack_t ss = { .ss_sp = malloc(1 << 16), .ss_size = 1 << 16 };
    sigaltstack(&ss, 0);
    sigaction(SIGSEGV, &sa, 0); sigaction(SIGBUS, &sa, 0); sigaction(SIGILL, &sa, 0); sigaction(SIGFPE, &sa, 0);
    setenv("RT_VERBOSE", "1", 0);
    if (rt_load_image(argv[1])) return 1;
    cpu = rt_new_cpu(8 << 20);
    rt_set_cpu(cpu);
    char msg[256];

    // 1. CRC32 (PhysX NxFoundation::crc32) vs host zlib
    size_t n = 64 << 20;
    uint8_t *buf = malloc(n);
    for (size_t k = 0; k < n; k++) buf[k] = (uint8_t)(k * 2654435761u >> 13);
    uint64_t r = 0;
    double t0 = now();
    int ok = guest(0x100184a58, &r, 2, (uint64_t)buf, (uint64_t)n);
    double tg = now() - t0;
    // PhysX variant: reflected CRC-32 table, initial value 0, no final xor
    uint32_t tbl[256];
    for (uint32_t i = 0; i < 256; i++) { uint32_t v = i; for (int k = 0; k < 8; k++) v = (v >> 1) ^ (v & 1 ? 0xEDB88320u : 0); tbl[i] = v; }
    t0 = now();
    uint32_t want = 0;
    for (size_t k = 0; k < n; k++) want = (want >> 8) ^ tbl[(uint8_t)(want ^ buf[k])];
    double th = now() - t0;
    snprintf(msg, sizeof msg, ok ? "guest 0x%08x host 0x%08x; 64 MB in %.0f ms translated vs %.0f ms same loop compiled natively" : "%4$s",
             (uint32_t)r, want, tg * 1e3, th * 1e3, ok ? "" : rt_last_failure);
    check("NxFoundation::crc32 matches host CRC", ok && (uint32_t)r == want, msg);

    // 2. LZO1X round trip through the game's own compressor and decompressor
    size_t ln = 16 << 20;
    uint8_t *src = malloc(ln), *cmp = malloc(ln + ln / 16 + 64 + 3), *out = malloc(ln), *wrk = calloc(1, 1 << 20);
    for (size_t k = 0; k < ln; k++) src[k] = "the quick brown fox jumps over the lazy dog "[(k / 7) % 44] ^ (uint8_t)((k >> 12) & 3);
    uint64_t clen = 0, olen = ln, rc1 = 1, rc2 = 1;
    t0 = now();
    ok = guest(0x1001f40d0, &rc1, 5, (uint64_t)src, (uint64_t)ln, (uint64_t)cmp, (uint64_t)&clen, (uint64_t)wrk);
    double tc = now() - t0;
    t0 = now();
    ok = ok && guest(0x1001eea90, &rc2, 5, (uint64_t)cmp, clen, (uint64_t)out, (uint64_t)&olen, (uint64_t)wrk);
    double td = now() - t0;
    int same = ok && (int)rc1 == 0 && (int)rc2 == 0 && olen == ln && !memcmp(src, out, ln);
    if (ok) snprintf(msg, sizeof msg, "16 MB -> %llu bytes; compress %.0f MB/s, decompress %.0f MB/s", (unsigned long long)clen, 16 / tc, 16 / td);
    check("lzo1x compress/decompress round trip", same, ok ? msg : rt_last_failure);

    // 3. FMatrix::Inverse (SSE-heavy) - check M * inv(M) == I
    float M[16] = {2, 0.5f, 0, 0,  0.25f, 3, 1, 0,  0, -1, 4, 0,  5, 6, 7, 1}, Inv[16];
    ok = guest(0x100435fa0, &r, 2, (uint64_t)Inv, (uint64_t)M);
    double err = 0;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) {
        double s = 0; for (int k = 0; k < 4; k++) s += M[i * 4 + k] * Inv[k * 4 + j];
        err = fmax(err, fabs(s - (i == j)));
    }
    snprintf(msg, sizeof msg, "max |M*inv(M) - I| = %.2g", err);
    check("FMatrix::Inverse", ok && err < 1e-5, ok ? msg : rt_last_failure);

    // 4. every static initializer, in order (constructs engine globals; exercises imports)
    int okinit = 0;
    char first_fail[32][200]; int nf = 0;
    t0 = now();
    for (int k = 0; k < ngmodinit; k++) {
        if (guest(gmodinit[k], 0, 0)) okinit++;
        else if (nf < 32) snprintf(first_fail[nf++], 200, "#%d 0x%llx: %s", k, (unsigned long long)gmodinit[k], rt_last_failure);
    }
    snprintf(msg, sizeof msg, "%d/%d ran to completion in %.0f ms, %d atexit handlers registered", okinit, ngmodinit, (now() - t0) * 1e3, rt_natexit);
    check("static initializers", okinit == ngmodinit, msg);
    for (int k = 0; k < nf; k++) printf("       %s\n", first_fail[k]);

    abi_checks();
    printf("\n%d/%d checks passed\n", pass, total);
    return pass == total ? 0 : 1;
}
