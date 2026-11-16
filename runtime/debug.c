// Diagnostics hooks called on entry to selected guest functions (see HOOKS in tools/recomp.py).
#include <stdio.h>
#include "rt.h"
#include "varargs.h"

// NxFoundation::FoundationSDK::errorImpl(this, NxErrorCode code, const char *file, int line,
//                                         bool *ignore, const char *fmt, va_list args)
// The 7th argument (a pointer to the guest va_list) is on the stack above the return address.
void H_physx_error(CPU *c) {
    const char *file = (const char *)C.rdx, *fmt = (const char *)C.r9;
    char msg[512] = "";
    uint8_t va_copy_[24];                       // read a copy so the guest's va_list is untouched
    uint64_t va = rd64s(C.rsp + 8);
    if (va && fmt) {
        memcpy(va_copy_, (void *)va, sizeof va_copy_);
        uint64_t slots[64];
        GuestVA g = gva_list(c, (uint64_t)va_copy_);
        if (gva_pack_printf(&g, fmt, 0, slots, 64)) vsnprintf(msg, sizeof msg, fmt, slots_va(slots));
        else snprintf(msg, sizeof msg, "%s", fmt);
    }
    fprintf(stderr, "physx: error %d at %s:%d: %s\n", (int)(uint32_t)C.rsi, file ? file : "?", (int)C.rcx, msg);
}
