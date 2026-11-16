// Hand-written import shims: callbacks into guest code, threads, struct-by-value calls,
// alert panels and C++ ABI entry points (compiled without ARC).
#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <IOKit/hid/IOHIDLib.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <ifaddrs.h>
#include <pthread.h>
#include <stdio.h>
#include "abi.h"
#include "image.h"
#include "varargs.h"

#define RET() (C.rsp += 8)

// ---------- guest function pointers handed to native code ----------
typedef struct { uint64_t fn; const char *sig; void *native; } CbEntry;
static CbEntry cbs[1024];
static int ncbs;
static os_unfair_lock cb_lock = OS_UNFAIR_LOCK_INIT;

// native function pointer for guest function pointer `p` (a host address) with signature `sig`
void *rt_guest_callback(uint64_t p, const char *sig) {
    if (!p) return 0;
    if (p >= IMPORT_BASE && p < IMPORT_ADDR(ngimports))       // an import such as free: use the host function
        return dlsym(RTLD_DEFAULT, gimports[(p - IMPORT_BASE) / 16].name + 1);
    os_unfair_lock_lock(&cb_lock);
    for (int k = 0; k < ncbs; k++)
        if (cbs[k].fn == p && !strcmp(cbs[k].sig, sig)) { void *n = cbs[k].native; os_unfair_lock_unlock(&cb_lock); return n; }
    Sig *s = sig_parse(sig);
    void *n = sig_closure(s, p - GSLIDE);
    if (ncbs < 1024) cbs[ncbs++] = (CbEntry){p, sig, n};
    os_unfair_lock_unlock(&cb_lock);
    return n;
}

// ---------- threads ----------
typedef struct { uint64_t fn, arg; } ThreadStart;

static void *thread_entry(void *p) {
    ThreadStart ts = *(ThreadStart *)p;
    free(p);
    CPU *c = rt_cpu();
    C.rdi = ts.arg;
    rt_call(c, ts.fn - GSLIDE);
    return (void *)C.rax;
}

void I__pthread_create(CPU *c) {
    ThreadStart *ts = malloc(sizeof *ts);
    ts->fn = C.rdx; ts->arg = C.rcx;
    C.rax = (uint32_t)pthread_create((pthread_t *)C.rdi, (const pthread_attr_t *)C.rsi, thread_entry, ts);
    RET();
}

void I__pthread_key_create(CPU *c) {
    C.rax = (uint32_t)pthread_key_create((pthread_key_t *)C.rdi, rt_guest_callback(C.rsi, "v^v"));
    RET();
}

// ---------- callbacks ----------
void I__qsort(CPU *c) {
    qsort((void *)C.rdi, C.rsi, C.rdx, rt_guest_callback(C.rcx, "i^v^v"));
    RET();
}

// void (*IOHIDDeviceCallback)(void *context, IOReturn result, void *sender, IOHIDDeviceRef device)
void I__IOHIDManagerRegisterDeviceMatchingCallback(CPU *c) {
    IOHIDManagerRegisterDeviceMatchingCallback((IOHIDManagerRef)C.rdi, rt_guest_callback(C.rsi, "v^vi^v^v"), (void *)C.rdx);
    RET();
}
void I__IOHIDManagerRegisterDeviceRemovalCallback(CPU *c) {
    IOHIDManagerRegisterDeviceRemovalCallback((IOHIDManagerRef)C.rdi, rt_guest_callback(C.rsi, "v^vi^v^v"), (void *)C.rdx);
    RET();
}

// OSStatus (*AudioConverterComplexInputDataProc)(AudioConverterRef, UInt32 *, AudioBufferList *,
//                                                AudioStreamPacketDescription **, void *)
void I__AudioConverterFillComplexBuffer(CPU *c) {
    C.rax = (uint32_t)AudioConverterFillComplexBuffer((AudioConverterRef)C.rdi, rt_guest_callback(C.rsi, "i^v^I^v^^v^v"),
                                                      (void *)C.rdx, (UInt32 *)C.rcx, (AudioBufferList *)C.r8,
                                                      (AudioStreamPacketDescription *)C.r9);
    RET();
}

// render callbacks are installed as a property holding a function pointer
// OSStatus (*AURenderCallback)(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *)
void I__AudioUnitSetProperty(CPU *c) {
    AudioUnitPropertyID id = (AudioUnitPropertyID)C.rsi;
    const void *data = (const void *)C.r8;
    AURenderCallbackStruct cb;
    if ((id == kAudioUnitProperty_SetRenderCallback || id == kAudioOutputUnitProperty_SetInputCallback) && data) {
        cb = *(const AURenderCallbackStruct *)data;
        cb.inputProc = rt_guest_callback((uint64_t)cb.inputProc, "i^v^I^vII^v");
        data = &cb;
    }
    C.rax = (uint32_t)AudioUnitSetProperty((AudioUnit)C.rdi, id, (AudioUnitScope)C.rdx, (AudioUnitElement)C.rcx, data, (UInt32)C.r9);
    RET();
}

// ---------- struct by value ----------
// CGEventRef CGEventCreateMouseEvent(CGEventSourceRef, CGEventType, CGPoint (xmm0, xmm1), CGMouseButton)
void I__CGEventCreateMouseEvent(CPU *c) {
    CGPoint p = {C.xmm[0].d[0], C.xmm[1].d[0]};
    C.rax = (uint64_t)CGEventCreateMouseEvent((CGEventSourceRef)C.rdi, (CGEventType)C.rsi, p, (CGMouseButton)C.rdx);
    RET();
}
void I__CGEventGetLocation(CPU *c) {
    CGPoint p = CGEventGetLocation((CGEventRef)C.rdi);
    double gs = rt_metal ? mgl_view_scale() : 1.0;          // the game's units (see send in objc.m)
    C.xmm[0].d[0] = p.x * gs; C.xmm[1].d[0] = p.y * gs;
    RET();
}
// CFIndex CFStringGetBytes(CFStringRef, CFRange (rsi, rdx), CFStringEncoding, UInt8, Boolean, UInt8 *, CFIndex, CFIndex *)
void I__CFStringGetBytes(CPU *c) {
    CFRange r = {(CFIndex)C.rsi, (CFIndex)C.rdx};
    C.rax = (uint64_t)CFStringGetBytes((CFStringRef)C.rdi, r, (CFStringEncoding)C.rcx, (UInt8)C.r8, (Boolean)C.r9,
                                       (UInt8 *)rd64(C.rsp + 8), (CFIndex)rd64(C.rsp + 16), (CFIndex *)rd64(C.rsp + 24));
    RET();
}

// ---------- alert panels: (title, msgFormat, default, alternate, other, ...) ----------
static void alert(CPU *c, int informational) {
    NSString *fmt = (NSString *)C.rsi;
    NSString *msg = fmt;
    if (fmt) {
        uint64_t slots[64]; GuestVA g = gva_regs(c, 5);
        if (gva_pack_printf(&g, fmt.UTF8String, 0, slots, 64))
            msg = [[[NSString alloc] initWithFormat:fmt arguments:slots_va(slots)] autorelease];
    }
    NSAlert *a = [[[NSAlert alloc] init] autorelease];
    a.alertStyle = informational ? NSAlertStyleInformational : NSAlertStyleWarning;
    if (C.rdi) a.messageText = (NSString *)C.rdi;
    if (msg) a.informativeText = msg;
    NSString *buttons[3] = {(NSString *)C.rdx, (NSString *)C.rcx, (NSString *)C.r8};
    for (int k = 0; k < 3; k++) if (buttons[k]) [a addButtonWithTitle:buttons[k]];
    NSModalResponse r = [a runModal];
    // NSAlertDefaultReturn = 1, NSAlertAlternateReturn = 0, NSAlertOtherReturn = -1
    C.rax = (uint64_t)(int64_t)(r == NSAlertFirstButtonReturn ? 1 : r == NSAlertSecondButtonReturn ? 0 : -1);
}
void I__NSRunAlertPanel(CPU *c) { alert(c, 0); RET(); }
void I__NSRunInformationalAlertPanel(CPU *c) { alert(c, 1); RET(); }

// ---------- C++ ABI: the game never throws, so these only run on a fatal path ----------
void I____cxa_pure_virtual(CPU *c) { unimpl_import(c, "__cxa_pure_virtual (pure virtual call)"); }
void I___ZSt9terminatev(CPU *c) { unimpl_import(c, "std::terminate"); }
void I____cxa_begin_catch(CPU *c) { unimpl_import(c, "__cxa_begin_catch (exception thrown)"); }
void I____cxa_end_catch(CPU *c) { unimpl_import(c, "__cxa_end_catch (exception thrown)"); }
void I____cxa_call_unexpected(CPU *c) { unimpl_import(c, "__cxa_call_unexpected (exception thrown)"); }
void I____cxa_guard_abort(CPU *c) { extern void __cxa_guard_abort(uint64_t *); __cxa_guard_abort((uint64_t *)C.rdi); RET(); }
void I__getifaddrs(CPU *c) { C.rax = (uint32_t)getifaddrs((struct ifaddrs **)C.rdi); RET(); }

// ULocalPlayer::CalcSceneView entry (HOOKS in tools/recomp.py). The game's camera constrains the view to
// 16:9 (ACamera::bConstrainAspectRatio), letterboxing other screen shapes. RT_FILL_SCREEN=1 clears the flag
// so the view fills the screen. Unconstrained, the engine's MaintainXFOV projection scales by a 16:9 constant
// (also used by FastProject/FastDeProject and the UI): horizontal max(1, K/aspect), vertical min(K, ...),
// which for a narrower screen keeps the 16:9 height and crops the sides. Setting K to the screen's aspect
// keeps the 16:9 width instead and shows more above and below.
#define ASPECT_16_9 0x1011afbe0ull                       // float 1.77778
void H_calc_scene_view(CPU *c) {
    static int on = -1;
    if (on < 0) on = getenv("RT_FILL_SCREEN") != 0;
    if (!on) return;
    uint64_t pc = rd64(C.rdi + 0x68);                    // ULocalPlayer::Actor (APlayerController)
    uint64_t cam = pc ? rd64(pc + 0x470) : 0;            // APlayerController::PlayerCamera
    if (cam) wr32(cam + 0x27c, rd32(cam + 0x27c) & ~2u); // ACamera::bConstrainAspectRatio
    uint32_t sx = C.r8 ? rd32(C.r8 + 0xb8) : 0, sy = C.r8 ? rd32(C.r8 + 0xbc) : 0;   // FViewport SizeX/SizeY
    float k = 16.0f / 9.0f;
    if (sx && sy && (float)sx / sy < k) k = (float)sx / sy;
    float cur;
    memcpy(&cur, (void *)G(ASPECT_16_9), 4);
    if (cur != k) memcpy((void *)G(ASPECT_16_9), &k, 4);
}
