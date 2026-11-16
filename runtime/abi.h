// System V x86_64 <-> native arm64 call marshalling driven by Objective-C type encodings.
// Used by the ObjC bridge (method types come from the runtime or the guest's own metadata)
// and by callback shims (encodings written by hand, e.g. "i^v^v" for a qsort comparator).
#pragma once
#include "rt.h"
#include <ffi/ffi.h>

#define SIG_MAX_ARGS 16

typedef struct {
    char kind;              // 'i' integer/pointer, 'f' float, 'd' double, 's' struct, 'v' void
    uint8_t is_signed;
    uint32_t size, align;
    ffi_type *ffi;
    // structs: SysV class of each eightbyte ('I' integer, 'S' sse) or 'M' memory
    char eb[2];
} ArgType;

typedef struct {
    int nargs;
    ArgType ret, args[SIG_MAX_ARGS];
    ffi_type *ffi_args[SIG_MAX_ARGS];
    ffi_cif cif;
} Sig;

// parse an ObjC type encoding ("v24@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16"); NULL on failure
Sig *sig_parse(const char *types);

// call native `fn` with arguments taken from the guest CPU; the first `skip_int` integer
// registers are not arguments (1 for objc_msgSend_stret, whose rdi is the result pointer).
// Writes the result to the guest registers (or to the guest result pointer for large structs).
void sig_call_native(CPU *c, const Sig *s, void *fn, int skip_int);

// a native function pointer that runs guest function `guest_fn` (link address) with signature `s`
void *sig_closure(const Sig *s, uint64_t guest_fn);

// per-thread guest CPU (created on first use, with its own guest stack)
CPU *rt_cpu(void);
void rt_set_cpu(CPU *c);
