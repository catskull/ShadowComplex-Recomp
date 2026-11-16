// Variadic imports: printf family, scanf family, open/fcntl/ioctl (see varargs.h).
#include "varargs.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>

GuestVA gva_regs(CPU *c, int fixed_int) {
    return (GuestVA){c, fixed_int, 0, c->rsp + 8, 0};
}
GuestVA gva_list(CPU *c, uint64_t va) {
    return (GuestVA){c, 0, 0, 0, va};
}

static uint64_t *ireg(CPU *c, int k) {
    uint64_t *r[] = {&c->rdi, &c->rsi, &c->rdx, &c->rcx, &c->r8, &c->r9};
    return r[k];
}

uint64_t gva_int(GuestVA *g) {
    if (g->va) {               // struct { u32 gp_offset, fp_offset; void *overflow_arg_area, *reg_save_area; }
        uint32_t gp = rd32(g->va);
        if (gp < 48) { wr32(g->va, gp + 8); return rd64(rd64(g->va + 16) + gp); }
        uint64_t o = rd64(g->va + 8); wr64(g->va + 8, o + 8); return rd64(o);
    }
    if (g->ni < 6) return *ireg(g->c, g->ni++);
    g->sp += 8;
    return rd64(g->sp - 8);
}

double gva_double(GuestVA *g) {
    if (g->va) {
        uint32_t fp = rd32(g->va + 4);
        if (fp < 176) { wr32(g->va + 4, fp + 16); return rdd(rd64(g->va + 16) + fp); }
        uint64_t o = rd64(g->va + 8); wr64(g->va + 8, o + 8); return rdd(o);
    }
    if (g->nf < 8) return g->c->xmm[g->nf++].d[0];
    g->sp += 8;
    return rdd(g->sp - 8);
}

static uint32_t ch(const void *f, int wide, int k) {
    return wide ? (uint32_t)((const int32_t *)f)[k] : ((const uint8_t *)f)[k];
}

int gva_pack_printf(GuestVA *g, const void *fmt, int wide, uint64_t *slots, int n) {
    int out = 0;
    for (int k = 0; ch(fmt, wide, k); k++) {
        if (ch(fmt, wide, k) != '%') continue;
        k++;
        if (ch(fmt, wide, k) == '%') continue;
        // flags, width, precision
        while (ch(fmt, wide, k) && strchr("-+ #0'", (int)ch(fmt, wide, k))) k++;
        if (ch(fmt, wide, k) == '*') { if (out < n) slots[out++] = (uint64_t)(int64_t)(int32_t)gva_int(g); k++; }
        while (ch(fmt, wide, k) >= '0' && ch(fmt, wide, k) <= '9') k++;
        if (ch(fmt, wide, k) == '.') {
            k++;
            if (ch(fmt, wide, k) == '*') { if (out < n) slots[out++] = (uint64_t)(int64_t)(int32_t)gva_int(g); k++; }
            while (ch(fmt, wide, k) >= '0' && ch(fmt, wide, k) <= '9') k++;
        }
        while (ch(fmt, wide, k) && strchr("hlqjztL", (int)ch(fmt, wide, k))) {
            if (ch(fmt, wide, k) == 'L') return 0;             // long double differs between ABIs
            k++;
        }
        uint32_t cv = ch(fmt, wide, k);
        if (!cv) break;
        if (out >= n) return 0;
        if (strchr("eEfFgGaA", (int)cv)) { double d = gva_double(g); memcpy(&slots[out++], &d, 8); }
        else if (strchr("diouxXcCsSpn@", (int)cv)) slots[out++] = gva_int(g);   // ints already promoted to 8-byte slots
        else return 0;
    }
    return 1;
}

int gva_pack_scanf(GuestVA *g, const void *fmt, int wide, uint64_t *slots, int n) {
    int out = 0;
    for (int k = 0; ch(fmt, wide, k); k++) {
        if (ch(fmt, wide, k) != '%') continue;
        k++;
        if (ch(fmt, wide, k) == '%') continue;
        int suppress = ch(fmt, wide, k) == '*';
        if (suppress) k++;
        while (ch(fmt, wide, k) >= '0' && ch(fmt, wide, k) <= '9') k++;
        while (ch(fmt, wide, k) && strchr("hlqjztL", (int)ch(fmt, wide, k))) k++;
        if (ch(fmt, wide, k) == '[') {                         // scanset: skip to the closing bracket
            k++;
            if (ch(fmt, wide, k) == '^') k++;
            if (ch(fmt, wide, k) == ']') k++;
            while (ch(fmt, wide, k) && ch(fmt, wide, k) != ']') k++;
        }
        if (!ch(fmt, wide, k)) break;
        if (!suppress) { if (out >= n) return 0; slots[out++] = gva_int(g); }
    }
    return 1;
}

#define RET() (C.rsp += 8)
#define NSLOTS 64

static void bad_format(CPU *c, const char *fn) {
    char b[96]; snprintf(b, sizeof b, "%s: format not supported", fn);
    unimpl_import(c, b);
}

void I__printf(CPU *c) {
    uint64_t s[NSLOTS]; GuestVA g = gva_regs(c, 1);
    if (!gva_pack_printf(&g, (void *)C.rdi, 0, s, NSLOTS)) bad_format(c, "printf");
    C.rax = (uint32_t)vprintf((const char *)C.rdi, slots_va(s)); RET();
}
void I__sprintf(CPU *c) {
    uint64_t s[NSLOTS]; GuestVA g = gva_regs(c, 2);
    if (!gva_pack_printf(&g, (void *)C.rsi, 0, s, NSLOTS)) bad_format(c, "sprintf");
    C.rax = (uint32_t)vsprintf((char *)C.rdi, (const char *)C.rsi, slots_va(s)); RET();
}
void I__snprintf(CPU *c) {
    uint64_t s[NSLOTS]; GuestVA g = gva_regs(c, 3);
    if (!gva_pack_printf(&g, (void *)C.rdx, 0, s, NSLOTS)) bad_format(c, "snprintf");
    C.rax = (uint32_t)vsnprintf((char *)C.rdi, C.rsi, (const char *)C.rdx, slots_va(s)); RET();
}
void I__vsnprintf(CPU *c) {
    uint64_t s[NSLOTS]; GuestVA g = gva_list(c, C.rcx);
    if (!gva_pack_printf(&g, (void *)C.rdx, 0, s, NSLOTS)) bad_format(c, "vsnprintf");
    C.rax = (uint32_t)vsnprintf((char *)C.rdi, C.rsi, (const char *)C.rdx, slots_va(s)); RET();
}
void I__swprintf(CPU *c) {
    uint64_t s[NSLOTS]; GuestVA g = gva_regs(c, 3);
    if (!gva_pack_printf(&g, (void *)C.rdx, 1, s, NSLOTS)) bad_format(c, "swprintf");
    C.rax = (uint32_t)vswprintf((wchar_t *)C.rdi, C.rsi, (const wchar_t *)C.rdx, slots_va(s)); RET();
}
void I__swscanf(CPU *c) {
    uint64_t s[NSLOTS]; GuestVA g = gva_regs(c, 2);
    if (!gva_pack_scanf(&g, (void *)C.rsi, 1, s, NSLOTS)) bad_format(c, "swscanf");
    C.rax = (uint32_t)vswscanf((const wchar_t *)C.rdi, (const wchar_t *)C.rsi, slots_va(s)); RET();
}
// fixed-shape variadics: the optional argument is a single integer/pointer
void I__open(CPU *c) { C.rax = (uint32_t)open((const char *)C.rdi, (int)C.rsi, (int)C.rdx); RET(); }
void I__fcntl(CPU *c) { C.rax = (uint32_t)fcntl((int)C.rdi, (int)C.rsi, C.rdx); RET(); }
void I__ioctl(CPU *c) { C.rax = (uint32_t)ioctl((int)C.rdi, (unsigned long)C.rsi, C.rdx); RET(); }
