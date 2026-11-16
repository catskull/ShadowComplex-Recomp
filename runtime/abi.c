// System V x86_64 <-> native arm64 call marshalling (see abi.h).
#include "abi.h"
#include "image.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

// ---------- type encodings ----------
static const char *skip_quals(const char *p) {
    while (*p && strchr("rnNoORVA", *p)) p++;
    return p;
}
static const char *skip_digits(const char *p) {
    while (*p == '-' || (*p >= '0' && *p <= '9')) p++;
    return p;
}

typedef struct { uint32_t off; char kind; } Scalar;   // flattened struct member

static ffi_type *scalar_ffi(char k, int sgn, uint32_t size) {
    if (k == 'f') return &ffi_type_float;
    if (k == 'd') return &ffi_type_double;
    switch (size) {
        case 1: return sgn ? &ffi_type_sint8 : &ffi_type_uint8;
        case 2: return sgn ? &ffi_type_sint16 : &ffi_type_uint16;
        case 4: return sgn ? &ffi_type_sint32 : &ffi_type_uint32;
        default: return sgn ? &ffi_type_sint64 : &ffi_type_uint64;
    }
}

// parse one type at *pp into t; struct members are appended to sc (offsets relative to base)
static int parse_type(const char **pp, ArgType *t, Scalar *sc, int *nsc, uint32_t base);

static int parse_scalar(char ch, ArgType *t) {
    t->is_signed = 0;
    switch (ch) {
        case 'c': t->is_signed = 1; /* fallthrough */
        case 'C': case 'B': t->kind = 'i'; t->size = t->align = 1; break;
        case 's': t->is_signed = 1; /* fallthrough */
        case 'S': t->kind = 'i'; t->size = t->align = 2; break;
        case 'i': case 'l': t->is_signed = 1; /* fallthrough */
        case 'I': case 'L': t->kind = 'i'; t->size = t->align = 4; break;
        case 'q': t->is_signed = 1; /* fallthrough */
        case 'Q': t->kind = 'i'; t->size = t->align = 8; break;
        case 'f': t->kind = 'f'; t->size = t->align = 4; break;
        case 'd': t->kind = 'd'; t->size = t->align = 8; break;
        case '@': case '#': case ':': case '*': case '^': case '?':
            t->kind = 'i'; t->size = t->align = 8; break;
        case 'v': t->kind = 'v'; t->size = 0; t->align = 1; break;
        default: return 0;
    }
    t->ffi = t->kind == 'v' ? &ffi_type_void : scalar_ffi(t->kind, t->is_signed, t->size);
    return 1;
}

static int parse_type(const char **pp, ArgType *t, Scalar *sc, int *nsc, uint32_t base) {
    const char *p = skip_quals(*pp);
    memset(t, 0, sizeof *t);
    if (*p == '^') {                       // pointer: skip pointee
        p++;
        ArgType dummy; Scalar ds[64]; int dn = 0;
        if (*p == '?' ) p++;
        else if (!parse_type(&p, &dummy, ds, &dn, 0)) return 0;
        parse_scalar('^', t);
    } else if (*p == '@') {
        p++;
        if (*p == '?') p++;                // block
        else if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
        parse_scalar('@', t);
    } else if (*p == '{' || *p == '(') {
        char close = *p == '{' ? '}' : ')';
        int is_union = *p == '(';
        p++;
        while (*p && *p != '=' && *p != close) p++;
        if (*p == '=') p++;
        ffi_type *st = calloc(1, sizeof(ffi_type));
        ffi_type **el = calloc(65, sizeof(ffi_type *));
        int n = 0;
        uint32_t off = 0, align = 1, size = 0;
        while (*p && *p != close) {
            if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; continue; }   // field name
            ArgType m;
            Scalar ms[64]; int mn = 0;          // member scalars, relative to the member
            if (!parse_type(&p, &m, ms, &mn, 0)) return 0;
            if (is_union) { if (m.size > size) size = m.size; }   // unions: treat as opaque bytes
            else {
                off = (off + m.align - 1) / m.align * m.align;
                if (m.kind != 's') ms[0] = (Scalar){0, m.kind}, mn = 1;
                for (int k = 0; k < mn && *nsc < 64; k++) sc[(*nsc)++] = (Scalar){base + off + ms[k].off, ms[k].kind};
                off += m.size;
            }
            if (m.align > align) align = m.align;
            if (n < 64) el[n++] = m.ffi;
        }
        if (*p == close) p++;
        if (is_union) {                         // opaque: pass as integer words
            n = 0;
            for (uint32_t k = 0; k < (size + 7) / 8 && n < 64; k++) el[n++] = &ffi_type_uint64;
            off = (size + 7) / 8 * 8; align = 8;
        }
        el[n] = 0;
        st->type = FFI_TYPE_STRUCT;
        st->elements = el;
        t->kind = 's';
        t->align = align;
        t->size = (off + align - 1) / align * align;
        t->ffi = st;
    } else if (*p == '[') {                    // array (only inside structs)
        p++;
        int count = atoi(p);
        p = skip_digits(p);
        ArgType e;
        Scalar es[64]; int en = 0;
        if (!parse_type(&p, &e, es, &en, 0)) return 0;
        if (*p == ']') p++;
        ffi_type *st = calloc(1, sizeof(ffi_type));
        ffi_type **el = calloc(count + 1, sizeof(ffi_type *));
        for (int k = 0; k < count; k++) {
            el[k] = e.ffi;
            if (e.kind != 's' && *nsc < 64) sc[(*nsc)++] = (Scalar){base + k * e.size, e.kind};
        }
        st->type = FFI_TYPE_STRUCT;
        st->elements = el;
        t->kind = 's'; t->size = e.size * count; t->align = e.align; t->ffi = st;
    } else if (*p == 'b') {                    // bitfield: approximate as an int
        p = skip_digits(p + 1);
        parse_scalar('I', t);
        *pp = p;
        return 1;
    } else {
        if (!parse_scalar(*p, t)) return 0;
        p++;
    }
    *pp = p;
    return 1;
}

static void classify(ArgType *t, const Scalar *sc, int nsc) {
    if (t->kind != 's') return;
    if (t->size > 16 || t->size == 0) { t->eb[0] = t->eb[1] = 'M'; return; }
    t->eb[0] = t->eb[1] = 'S';
    int any[2] = {0, 0};
    for (int k = 0; k < nsc; k++) {
        int e = sc[k].off / 8;
        if (e > 1) continue;
        any[e] = 1;
        if (sc[k].kind == 'i') t->eb[e] = 'I';
    }
    for (int e = 0; e < 2; e++) if (!any[e] && t->size > 8 * e) t->eb[e] = 'I';   // padding/opaque bytes
    if (t->size <= 8) t->eb[1] = 0;
}

static int parse_one(const char **pp, ArgType *t) {
    Scalar sc[64]; int nsc = 0;
    if (!parse_type(pp, t, sc, &nsc, 0)) return 0;
    classify(t, sc, nsc);
    *pp = skip_digits(*pp);
    return 1;
}

Sig *sig_parse(const char *types) {
    Sig *s = calloc(1, sizeof(Sig));
    const char *p = types;
    if (!parse_one(&p, &s->ret)) goto bad;
    while (*skip_quals(p)) {
        if (s->nargs >= SIG_MAX_ARGS) goto bad;
        if (!parse_one(&p, &s->args[s->nargs])) goto bad;
        s->ffi_args[s->nargs] = s->args[s->nargs].ffi;
        s->nargs++;
    }
    if (ffi_prep_cif(&s->cif, FFI_DEFAULT_ABI, s->nargs, s->ret.ffi, s->ffi_args) != FFI_OK) goto bad;
    return s;
bad:
    fprintf(stderr, "abi: cannot parse type encoding '%s'\n", types);
    free(s);
    return 0;
}

// ---------- guest -> native ----------
static uint64_t *ireg(CPU *c, int k) {
    switch (k) {
        case 0: return &c->rdi; case 1: return &c->rsi; case 2: return &c->rdx;
        case 3: return &c->rcx; case 4: return &c->r8; default: return &c->r9;
    }
}

static void store_scalar(void *dst, const ArgType *t, uint64_t bits) {
    memcpy(dst, &bits, t->size ? t->size : 8);
}

void sig_call_native(CPU *c, const Sig *s, void *fn, int skip_int) {
    _Alignas(16) uint8_t storage[SIG_MAX_ARGS][64];
    void *argv[SIG_MAX_ARGS];
    int ni = skip_int, nf = 0;
    uint64_t sp = C.rsp + 8;                      // first stack argument (above return address)
    for (int k = 0; k < s->nargs; k++) {
        const ArgType *t = &s->args[k];
        void *dst = argv[k] = storage[k];
        if (t->kind == 'i') {
            store_scalar(dst, t, ni < 6 ? *ireg(c, ni++) : (sp += 8, rd64(sp - 8)));
        } else if (t->kind == 'f') {
            float v = nf < 8 ? C.xmm[nf++].f[0] : (sp += 8, rdf(sp - 8));
            memcpy(dst, &v, 4);
        } else if (t->kind == 'd') {
            double v = nf < 8 ? C.xmm[nf++].d[0] : (sp += 8, rdd(sp - 8));
            memcpy(dst, &v, 8);
        } else {
            int wi = 0, wf = 0, n8 = (t->size + 7) / 8;
            for (int e = 0; e < n8 && t->eb[0] != 'M'; e++) { if (t->eb[e] == 'I') wi++; else wf++; }
            if (t->eb[0] == 'M' || ni + wi > 6 || nf + wf > 8) {
                if (t->align > 8) sp = (sp + 15) & ~15ull;
                if (t->size > sizeof storage[k]) { argv[k] = (void *)sp; }      // large: use guest copy in place
                else memcpy(dst, (void *)sp, t->size);
                sp += (t->size + 7) & ~7u;
            } else {
                uint64_t w[2];
                for (int e = 0; e < n8; e++) w[e] = t->eb[e] == 'I' ? *ireg(c, ni++) : C.xmm[nf++].q[0];
                memcpy(dst, w, t->size);
            }
        }
    }
    _Alignas(16) uint8_t ret[256];
    uint64_t sret = skip_int ? C.rdi : 0;
    void *rp = (s->ret.kind == 's' && s->ret.eb[0] == 'M' && sret) ? (void *)sret : ret;
    memset(ret, 0, 16);
    ffi_call((ffi_cif *)&s->cif, fn, rp, argv);
    const ArgType *r = &s->ret;
    if (r->kind == 'i') {
        uint64_t v = 0;
        memcpy(&v, ret, r->size);
        if (r->is_signed && r->size < 8) v = (uint64_t)((int64_t)(v << (64 - 8 * r->size)) >> (64 - 8 * r->size));
        C.rax = v;
    } else if (r->kind == 'f') memcpy(&C.xmm[0].f[0], ret, 4);
    else if (r->kind == 'd') memcpy(&C.xmm[0].d[0], ret, 8);
    else if (r->kind == 's') {
        if (r->eb[0] == 'M') {
            if (!sret) { fprintf(stderr, "abi: large struct return without result pointer\n"); abort(); }
            C.rax = sret;
        } else {
            int oi = 0, of = 0, n8 = (r->size + 7) / 8;
            for (int e = 0; e < n8; e++) {
                uint64_t w = 0; memcpy(&w, ret + 8 * e, (r->size - 8 * e) < 8 ? r->size - 8 * e : 8);
                if (r->eb[e] == 'I') *(oi++ ? &C.rdx : &C.rax) = w;
                else C.xmm[of++].q[0] = w;
            }
        }
    }
}

// ---------- native -> guest ----------
typedef struct { const Sig *sig; uint64_t guest_fn; } ClosureData;

static void closure_entry(ffi_cif *cif, void *ret, void **args, void *ud) {
    (void)cif;
    ClosureData *cd = ud;
    const Sig *s = cd->sig;
    CPU *c = rt_cpu();
    CPU saved = *c;                                 // native callers expect every guest register intact
    int ni = 0, nf = 0;
    // large struct return: guest writes through a hidden pointer in rdi
    int sret = s->ret.kind == 's' && s->ret.eb[0] == 'M';
    if (sret) *ireg(c, ni++) = (uint64_t)ret;
    uint64_t stack_words[64]; int ns = 0;
    for (int k = 0; k < s->nargs; k++) {
        const ArgType *t = &s->args[k];
        if (t->kind == 'i') {
            uint64_t v = 0; memcpy(&v, args[k], t->size);
            if (t->is_signed && t->size < 8) v = (uint64_t)((int64_t)(v << (64 - 8 * t->size)) >> (64 - 8 * t->size));
            if (ni < 6) *ireg(c, ni++) = v; else stack_words[ns++] = v;
        } else if (t->kind == 'f' || t->kind == 'd') {
            uint64_t v = 0; memcpy(&v, args[k], t->size);
            if (nf < 8) { memset(&C.xmm[nf], 0, 16); C.xmm[nf++].q[0] = v; } else stack_words[ns++] = v;
        } else {
            int wi = 0, wf = 0, n8 = (t->size + 7) / 8;
            for (int e = 0; e < n8 && t->eb[0] != 'M'; e++) { if (t->eb[e] == 'I') wi++; else wf++; }
            uint64_t w[8] = {0};
            memcpy(w, args[k], t->size < 64 ? t->size : 64);
            if (t->eb[0] == 'M' || ni + wi > 6 || nf + wf > 8) {
                for (int e = 0; e < n8 && ns < 64; e++) stack_words[ns++] = w[e];
            } else {
                for (int e = 0; e < n8; e++) {
                    if (t->eb[e] == 'I') *ireg(c, ni++) = w[e];
                    else { memset(&C.xmm[nf], 0, 16); C.xmm[nf++].q[0] = w[e]; }
                }
            }
        }
    }
    C.rax = nf;                                     // %al = vector registers used (varargs callees)
    uint64_t sp = (saved.rsp - 128 - 8 * ns) & ~15ull;   // keep clear of the caller's red zone
    for (int k = 0; k < ns; k++) wr64(sp + 8 * k, stack_words[k]);
    C.rsp = sp;
    rt_call(c, cd->guest_fn);
    const ArgType *r = &s->ret;
    if (r->kind == 'i') {
        uint64_t v = C.rax;
        if (r->size < 8) {                          // libffi wants small ints widened to ffi_arg
            if (r->is_signed) v = (uint64_t)((int64_t)(v << (64 - 8 * r->size)) >> (64 - 8 * r->size));
            else v &= (1ull << (8 * r->size)) - 1;
        }
        memcpy(ret, &v, 8);
    } else if (r->kind == 'f') memcpy(ret, &C.xmm[0].f[0], 4);
    else if (r->kind == 'd') memcpy(ret, &C.xmm[0].d[0], 8);
    else if (r->kind == 's' && !sret) {
        int oi = 0, of = 0;
        for (int e = 0; e < (int)((r->size + 7) / 8); e++) {
            uint64_t w = r->eb[e] == 'I' ? (oi++ ? C.rdx : C.rax) : C.xmm[of++].q[0];
            memcpy((uint8_t *)ret + 8 * e, &w, (r->size - 8 * e) < 8 ? r->size - 8 * e : 8);
        }
    }
    *c = saved;
}

void *sig_closure(const Sig *s, uint64_t guest_fn) {
    void *code;
    ffi_closure *cl = ffi_closure_alloc(sizeof(ffi_closure), &code);
    ClosureData *cd = malloc(sizeof *cd);
    cd->sig = s; cd->guest_fn = guest_fn;
    if (!cl || ffi_prep_closure_loc(cl, (ffi_cif *)&s->cif, closure_entry, cd, code) != FFI_OK) {
        fprintf(stderr, "abi: closure allocation failed\n"); abort();
    }
    return code;
}

// ---------- per-thread CPU ----------
static pthread_key_t cpu_key;
static pthread_once_t cpu_once = PTHREAD_ONCE_INIT;
static void cpu_key_init(void) { pthread_key_create(&cpu_key, 0); }

CPU *rt_cpu(void) {
    pthread_once(&cpu_once, cpu_key_init);
    CPU *c = pthread_getspecific(cpu_key);
    if (!c) { c = rt_new_cpu(8 << 20); pthread_setspecific(cpu_key, c); }
    return c;
}
void rt_set_cpu(CPU *c) { pthread_once(&cpu_once, cpu_key_init); pthread_setspecific(cpu_key, c); }
