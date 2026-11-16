// Loader, indirect-call dispatch and failure paths for the recompiled guest.
#include "rt.h"
#include "image.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static uint64_t text_lo, text_hi;

// --- failure paths: report, then let a test harness recover (rt_trap) or abort ---
sigjmp_buf *rt_trap;
const char *rt_last_failure;
static char failure_buf[512];

static void fail(CPU *c, const char *what) {
    snprintf(failure_buf, sizeof failure_buf, "%s (in guest fn 0x%llx)", what, (unsigned long long)c->fn);
    rt_last_failure = failure_buf;
    if (rt_trap) siglongjmp(*rt_trap, 1);
    fprintf(stderr, "fatal: %s\n", failure_buf);
    abort();
}

void unimpl_import(CPU *c, const char *name) {
    char b[256]; snprintf(b, sizeof b, "unimplemented import %s", name); fail(c, b);
}
void missing_import(CPU *c) { fail(c, "call through unbound import slot"); }
void missing_func(CPU *c, uint64_t t) {
    char b[128]; snprintf(b, sizeof b, "call to unknown guest address 0x%llx", (unsigned long long)(t - GSLIDE)); fail(c, b);
}
void bad_insn(CPU *c, uint64_t a) {
    char b[128]; snprintf(b, sizeof b, "untranslated instruction at 0x%llx", (unsigned long long)a); fail(c, b);
}
void bad_jump(CPU *c, uint64_t t, uint64_t a) {
    char b[128]; snprintf(b, sizeof b, "jump table at 0x%llx: target 0x%llx", (unsigned long long)a, (unsigned long long)(t - GSLIDE)); fail(c, b);
}

#define JMP_MAGIC 0x524A4D50u   /* "PMJR" */
RtJmp *rt_jmp_slot(CPU *c, uint64_t buf) {
    (void)c;
    if (rd32(buf + 8) != JMP_MAGIC) { wr64(buf, (uint64_t)calloc(1, sizeof(RtJmp))); wr32(buf + 8, JMP_MAGIC); }
    return (RtJmp *)rd64(buf);
}
void I__longjmp(CPU *c) {
    RtJmp *j = rt_jmp_slot(c, C.rdi);
    j->val = (int)C.rsi ? (int)C.rsi : 1;
    _longjmp(j->host, 1);
}

// host functions given guest-callable addresses (vtables of host-implemented C++ objects)
#define HOSTFN_BASE 0x320000000000ull
#define HOSTFN_MAX 8192
static gfn hostfns[HOSTFN_MAX];
static int nhostfns;
uint64_t rt_host_fn(gfn f) {
    for (int k = 0; k < nhostfns; k++) if (hostfns[k] == f) return HOSTFN_BASE + 16ull * k;
    if (nhostfns == HOSTFN_MAX) { fprintf(stderr, "rt_host_fn: table full\n"); abort(); }
    hostfns[nhostfns] = f;
    return HOSTFN_BASE + 16ull * nhostfns++;
}

void rt_cpuid(CPU *c) {
    // a plain SSE3/SSSE3-capable x86_64 with no AVX, so the engine stays on the paths we translate
    uint32_t leaf = (uint32_t)C.rax;
    uint32_t a = 0, b = 0, cc = 0, d = 0;
    if (leaf == 0) { a = 1; b = 0x756e6547; d = 0x49656e69; cc = 0x6c65746e; }   // "GenuineIntel"
    else if (leaf == 1) { a = 0x000206a7; d = (1u << 25) | (1u << 26) | (1u << 23) | (1u << 15) | 1u; cc = 1u | (1u << 9); }
    C.rax = a; C.rbx = b; C.rcx = cc; C.rdx = d;
}

// --- dispatch ---
static gfn find_func(uint64_t guest) {
    int lo = 0, hi = ngfuncs - 1;
    while (lo <= hi) {
        int m = (lo + hi) >> 1;
        if (gfuncs[m].addr == guest) return gfuncs[m].fn;
        if (gfuncs[m].addr < guest) lo = m + 1; else hi = m - 1;
    }
    return 0;
}

// direct-mapped dispatch: one slot per 16 bytes of guest text, holding the function that starts
// exactly there (86% of functions are 16-byte aligned); the rest go in an open-addressed hash
// table keyed by host address (PhysX calls unaligned functions indirectly in its solver loops)
static gfn *fastfn;
static struct { uint64_t addr; gfn fn; } *oddfn;
static uint64_t oddmask;
static inline uint64_t odd_hash(uint64_t a) { return (a * 0x9E3779B97F4A7C15ull) >> 40; }
static void build_fastfn(void) {
    fastfn = calloc(((text_hi - text_lo) >> 4) + 1, sizeof(gfn));
    int nodd = 0;
    for (int k = 0; k < ngfuncs; k++) {
        uint64_t off = G(gfuncs[k].addr) - text_lo;
        if (!(off & 15)) fastfn[off >> 4] = gfuncs[k].fn; else nodd++;
    }
    uint64_t size = 1;
    while (size < 4ull * nodd + 16) size <<= 1;
    oddmask = size - 1;
    oddfn = calloc(size, sizeof *oddfn);
    for (int k = 0; k < ngfuncs; k++) {
        uint64_t a = G(gfuncs[k].addr);
        if (!((a - text_lo) & 15)) continue;
        uint64_t h = odd_hash(a) & oddmask;
        while (oddfn[h].addr) h = (h + 1) & oddmask;
        oddfn[h].addr = a; oddfn[h].fn = gfuncs[k].fn;
    }
}

void call_ind(CPU *c, uint64_t t) {
    uint64_t off = t - text_lo;
    if (__builtin_expect(off < text_hi - text_lo, 1)) {
        if (__builtin_expect(!(off & 15), 1)) {
            gfn f = fastfn[off >> 4];
            if (__builtin_expect(f != 0, 1)) { f(c); return; }
        } else {
            for (uint64_t h = odd_hash(t) & oddmask; oddfn[h].addr; h = (h + 1) & oddmask)
                if (oddfn[h].addr == t) { oddfn[h].fn(c); return; }
        }
    }
    if (t >= text_lo && t < text_hi) {
        gfn f = find_func(t - GSLIDE);
        if (f) { f(c); return; }
        missing_func(c, t);
        return;
    }
    if (t >= IMPORT_BASE && t < IMPORT_ADDR(ngimports)) {
        gimports[(t - IMPORT_BASE) / 16].thunk(c);
        return;
    }
    if (t >= HOSTFN_BASE && t < HOSTFN_BASE + 16ull * nhostfns) {
        hostfns[(t - HOSTFN_BASE) / 16](c);
        return;
    }
    char b[128]; snprintf(b, sizeof b, "indirect call to non-guest address 0x%llx", (unsigned long long)t); fail(c, b);
}

#define RET_SENTINEL 0x5E471E15E471E1ull
void rt_call(CPU *c, uint64_t guest_fn) {
    PUSH(RET_SENTINEL);
    call_ind(c, G(guest_fn));
}

CPU *rt_new_cpu(size_t stack_size) {
    CPU *c = calloc(1, sizeof(CPU));
    uint8_t *s = mmap(0, stack_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    c->stack_lo = (uint64_t)s;
    c->stack_hi = (uint64_t)s + stack_size;
    c->rsp = c->stack_hi - 64;
    c->mxcsr = 0x1F80;
    return c;
}

// --- loader ---
// true when p lies in an instruction section of the host image that defines it
// (constants such as kCFAllocatorDefault live in __TEXT,__const, so segments are not enough)
static int is_executable(void *p) {
    Dl_info di;
    if (!dladdr(p, &di) || !di.dli_fbase) return 0;
    const struct mach_header_64 *h = di.dli_fbase;
    const struct load_command *lc = (const void *)(h + 1);
    uint64_t text_vm = 0;
    for (uint32_t k = 0; k < h->ncmds; k++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *sg = (const void *)lc;
        if (!strcmp(sg->segname, "__TEXT")) text_vm = sg->vmaddr;   // __TEXT comes first and starts at the header
        const struct section_64 *sec = (const void *)(sg + 1);
        for (uint32_t s = 0; s < sg->nsects; s++) {
            uint64_t lo = sec[s].addr - text_vm + (uint64_t)h;
            if ((uint64_t)p >= lo && (uint64_t)p < lo + sec[s].size)
                return (sec[s].flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) != 0;
        }
    }
    return 0;
}

int rt_load_image(const char *path) {
    uint64_t end = 0;
    for (int k = 0; k < ngsegs; k++)
        if (gsegs[k].vmaddr + gsegs[k].vmsize > end) end = gsegs[k].vmaddr + gsegs[k].vmsize;
    size_t size = end - GUEST_LINK_BASE;
    void *base = mmap((void *)GUEST_HOST_BASE, size, PROT_READ | PROT_WRITE,
                      MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
    if (base != (void *)GUEST_HOST_BASE) { perror("map guest image"); return -1; }
    // reserve the import trampoline range so its addresses never alias real memory
    if (mmap((void *)IMPORT_BASE, 16ull * ngimports + 4096, PROT_NONE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0)
            != (void *)IMPORT_BASE) { perror("reserve import range"); return -1; }
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); return -1; }
    for (int k = 0; k < ngsegs; k++) {
        const GSeg *s = &gsegs[k];
        if (pread(fd, (void *)G(s->vmaddr), s->filesize, s->fileoff) != (ssize_t)s->filesize) { perror("read segment"); return -1; }
        if (!strcmp(s->name, "__TEXT")) { text_lo = G(s->vmaddr); text_hi = G(s->vmaddr + s->vmsize); }
    }
    close(fd);
    build_fastfn();
    for (int k = 0; k < ngrebases; k++) {
        uint64_t *p = (uint64_t *)G(GUEST_LINK_BASE + grebases[k]);
        *p += GSLIDE;
    }
    for (int k = 0; k < ngselfbinds; k++)
        wr64(G(gselfbinds[k].addr), G(gselfbinds[k].value));
    int nfun = 0, ndata = 0, nmissing = 0;
    static char *resolved;
    resolved = calloc(ngimports, 1);
    uint64_t *value = calloc(ngimports, sizeof(uint64_t));
    for (int k = 0; k < ngimports; k++) {
        void *p = dlsym(RTLD_DEFAULT, gimports[k].name + 1);
        if (p && !is_executable(p)) { value[k] = (uint64_t)p; resolved[k] = 2; ndata++; }
        else { value[k] = IMPORT_ADDR(k); resolved[k] = 1; if (p) nfun++; else nmissing++; }
    }
    for (int k = 0; k < ngbinds; k++) {
        const GBind *b = &gbinds[k];
        wr64(G(b->addr), value[b->import] + (resolved[b->import] == 2 ? b->addend : 0));
    }
    free(value);
    if (getenv("RT_VERBOSE"))
        fprintf(stderr, "loaded guest image at %p (%zu MB): %d rebases, %d binds, imports: %d host functions, %d host data, %d not on host\n",
                base, size >> 20, ngrebases, ngbinds + ngselfbinds, nfun, ndata, nmissing);
    return 0;
}
