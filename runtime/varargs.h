// Guest variadic arguments: read System V x86_64 varargs (from registers/stack or from a guest
// va_list) in the order a format string consumes them, and repack them as an Apple arm64
// va_list, which is a plain pointer to consecutive 8-byte slots.
#pragma once
#include "rt.h"
#include <stdarg.h>
#include <wchar.h>

typedef struct {
    CPU *c;
    int ni, nf;            // next integer / sse register
    uint64_t sp;           // next stack argument
    uint64_t va;           // guest va_list (0 = read from registers/stack)
} GuestVA;

// arguments start after `fixed_int` integer registers (and no float registers)
GuestVA gva_regs(CPU *c, int fixed_int);
GuestVA gva_list(CPU *c, uint64_t guest_va_list);
uint64_t gva_int(GuestVA *g);
double gva_double(GuestVA *g);

// pack the arguments a printf/wprintf/NSString format consumes; returns a host va_list view
// of `slots` (capacity `n`). `wide` = format is wchar_t. Unsupported specs return 0.
int gva_pack_printf(GuestVA *g, const void *fmt, int wide, uint64_t *slots, int n);
// scanf family: every non-suppressed conversion takes a pointer
int gva_pack_scanf(GuestVA *g, const void *fmt, int wide, uint64_t *slots, int n);

static inline va_list slots_va(uint64_t *slots) { return (va_list)(void *)slots; }
