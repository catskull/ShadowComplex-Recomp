// Loader tables emitted by tools/imagegen.py (gen/image.c) and tools/recomp.py (gen/tables.c).
#pragma once
#include "rt.h"

typedef struct { const char *name; uint64_t vmaddr, vmsize, fileoff, filesize; } GSeg;
typedef struct { uint64_t addr; int import; int64_t addend; } GBind;
typedef struct { uint64_t addr, value; } GSelfBind;
typedef struct { const char *name; gfn thunk; } GImport;
typedef struct { const char *segment, *name; uint64_t addr, size; } GSect;

extern const GSeg gsegs[];            extern const int ngsegs;
extern const uint32_t grebases[];     extern const int ngrebases;   // offsets from the link base
extern const GBind gbinds[];          extern const int ngbinds;
extern const GSelfBind gselfbinds[];  extern const int ngselfbinds;
extern const GImport gimports[];      extern const int ngimports;
extern const uint64_t gmodinit[];     extern const int ngmodinit;
extern const uint64_t gentry;
extern const GSect gsects[];          extern const int ngsects;
const GSect *rt_section(const char *name);   // by section name (first match), or NULL
extern const GFunc gfuncs[];          extern const int ngfuncs;      // sorted by addr

// import trampolines: guest-visible fake addresses that call_ind maps to host thunks
#define IMPORT_BASE 0x310000000000ull
#define IMPORT_ADDR(k) (IMPORT_BASE + 16ull * (k))

int rt_load_image(const char *path);
CPU *rt_new_cpu(size_t stack_size);
void rt_call(CPU *c, uint64_t guest_fn);   // run guest function with args already in registers
uint64_t rt_host_fn(gfn f);                // guest-callable address for a host thunk
