// Objective-C bridge (compiled without ARC).
// - registers the guest's own classes with the host runtime; their methods become libffi
//   closures that enter guest code
// - rewrites the guest's selector, class and super references to host objects
// - objc_msgSend / _stret / Super2 from guest code: marshal per the method's type encoding
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include "abi.h"
#include "image.h"
#include "varargs.h"

#define RET() (C.rsp += 8)

const GSect *rt_section(const char *name) {
    for (int k = 0; k < ngsects; k++) if (!strcmp(gsects[k].name, name)) return &gsects[k];
    return 0;
}

// ---------- guest classes ----------
// guest metadata is the standard 64-bit objc2 layout (identical on x86_64 and arm64)
typedef struct { uint64_t isa, superclass, cache, vtable, data; } GClass;
typedef struct {
    uint32_t flags, instanceStart, instanceSize, reserved;
    uint64_t ivarLayout, name, baseMethods, baseProtocols, ivars, weakIvarLayout, baseProperties;
} GClassRO;
typedef struct { uint64_t name, types, imp; } GMethod;
typedef struct { uint64_t offset, name, type; uint32_t alignment_raw, size; } GIvar;

static uint64_t guest_lo, guest_hi;
static int in_guest(uint64_t p) { return p >= guest_lo && p < guest_hi; }

#define MAX_GCLASSES 64
static struct { uint64_t guest; Class host; } classmap[2 * MAX_GCLASSES];
static int nclassmap;

static Class host_class_for(uint64_t guest) {
    for (int k = 0; k < nclassmap; k++) if (classmap[k].guest == guest) return classmap[k].host;
    return 0;
}

static const GClassRO *ro_of(uint64_t cls) { return (const GClassRO *)(((const GClass *)cls)->data & ~7ull); }

// implementations of guest methods, so geometry is converted only when AppKit receives it (see send)
#define MAX_GUEST_IMPS 1024
static IMP guest_imps[MAX_GUEST_IMPS];
static int nguest_imps;
static int is_guest_imp(IMP imp) {
    for (int k = 0; k < nguest_imps; k++) if (guest_imps[k] == imp) return 1;
    return 0;
}

static void add_methods(Class host, uint64_t list) {
    if (!list) return;
    uint32_t entsize = rd32(list) & ~3u, count = rd32(list + 4);
    for (uint32_t k = 0; k < count; k++) {
        const GMethod *m = (const GMethod *)(list + 8 + (uint64_t)k * entsize);
        const char *types = (const char *)m->types;
        Sig *s = sig_parse(types);
        if (!s) { fprintf(stderr, "objc: skipping %s (types %s)\n", (const char *)m->name, types); continue; }
        IMP imp = (IMP)sig_closure(s, m->imp - GSLIDE);
        class_addMethod(host, sel_registerName((const char *)m->name), imp, types);
        if (nguest_imps < MAX_GUEST_IMPS) guest_imps[nguest_imps++] = imp;
    }
}

static Class register_class(uint64_t g) {
    Class have = host_class_for(g);
    if (have) return have;
    const GClass *gc = (const GClass *)g;
    Class super = in_guest(gc->superclass) ? register_class(gc->superclass) : (Class)gc->superclass;
    const GClassRO *ro = ro_of(g);
    const char *name = (const char *)ro->name;
    Class host = objc_allocateClassPair(super, name, 0);
    if (!host) { fprintf(stderr, "objc: cannot allocate class %s\n", name); abort(); }
    if (ro->ivars) {
        uint32_t entsize = rd32(ro->ivars), count = rd32(ro->ivars + 4);
        for (uint32_t k = 0; k < count; k++) {
            const GIvar *iv = (const GIvar *)(ro->ivars + 8 + (uint64_t)k * entsize);
            uint8_t lg = iv->alignment_raw == 0xFFFFFFFFu ? 3 : (uint8_t)iv->alignment_raw;
            class_addIvar(host, (const char *)iv->name, iv->size, lg, (const char *)iv->type);
        }
    }
    add_methods(host, ro->baseMethods);
    add_methods(object_getClass(host), ro_of(gc->isa)->baseMethods);
    if (ro->baseProtocols) {
        uint64_t n = rd64(ro->baseProtocols);
        for (uint64_t k = 0; k < n; k++) {
            uint64_t proto = rd64(ro->baseProtocols + 8 + 8 * k);
            Protocol *p = objc_getProtocol((const char *)rd64(proto + 8));
            if (p) class_addProtocol(host, p);
        }
    }
    objc_registerClassPair(host);
    // the guest reads ivar offsets from its own variables: point them at the host layout
    if (ro->ivars) {
        uint32_t entsize = rd32(ro->ivars), count = rd32(ro->ivars + 4);
        for (uint32_t k = 0; k < count; k++) {
            const GIvar *iv = (const GIvar *)(ro->ivars + 8 + (uint64_t)k * entsize);
            Ivar hv = class_getInstanceVariable(host, (const char *)iv->name);
            if (iv->offset) wr32(iv->offset, (uint32_t)ivar_getOffset(hv));
        }
    }
    classmap[nclassmap++] = (typeof(classmap[0])){g, host};
    classmap[nclassmap++] = (typeof(classmap[0])){gc->isa, object_getClass(host)};
    if (getenv("RT_VERBOSE")) fprintf(stderr, "objc: registered guest class %s : %s\n", name, class_getName(super));
    return host;
}

void rt_objc_init(void) {
    guest_lo = G(gsegs[0].vmaddr);
    guest_hi = G(gsegs[ngsegs - 1].vmaddr + gsegs[ngsegs - 1].vmsize);
    const GSect *s;
    if ((s = rt_section("__objc_selrefs")))
        for (uint64_t a = G(s->addr); a < G(s->addr + s->size); a += 8)
            wr64(a, (uint64_t)sel_registerName((const char *)rd64(a)));
    if ((s = rt_section("__objc_classlist")))
        for (uint64_t a = G(s->addr); a < G(s->addr + s->size); a += 8)
            register_class(rd64(a));
    const char *refs[] = {"__objc_classrefs", "__objc_superrefs"};
    for (int r = 0; r < 2; r++)
        if ((s = rt_section(refs[r])))
            for (uint64_t a = G(s->addr); a < G(s->addr + s->size); a += 8) {
                Class h = host_class_for(rd64(a));
                if (h) wr64(a, (uint64_t)h);
                else if (in_guest(rd64(a))) fprintf(stderr, "objc: unresolved guest class ref at %llx\n", a - GSLIDE);
            }
}

// ---------- signature cache ----------
typedef struct { Class cls; SEL sel; const Sig *sig; } SigEntry;
#define SIGCACHE 4096
static SigEntry sigcache[SIGCACHE];
static os_unfair_lock sig_lock = OS_UNFAIR_LOCK_INIT;

static const char *encoding_from_signature(NSMethodSignature *ms) {
    NSMutableString *e = [NSMutableString stringWithUTF8String:ms.methodReturnType];
    for (NSUInteger k = 0; k < ms.numberOfArguments; k++) [e appendFormat:@"%s", [ms getArgumentTypeAtIndex:k]];
    return strdup(e.UTF8String);
}

// signature for sending `sel` to an instance of `cls` (for class receivers, cls is the metaclass)
static const Sig *sig_for(id recv, Class cls, SEL sel) {
    uint64_t h = (((uint64_t)cls >> 4) ^ ((uint64_t)sel >> 3) * 0x9E3779B97F4A7C15ull) % SIGCACHE;
    os_unfair_lock_lock(&sig_lock);
    for (uint64_t k = h;; k = (k + 1) % SIGCACHE) {
        if (sigcache[k].cls == cls && sigcache[k].sel == sel) { const Sig *s = sigcache[k].sig; os_unfair_lock_unlock(&sig_lock); return s; }
        if (!sigcache[k].cls) break;
    }
    os_unfair_lock_unlock(&sig_lock);
    Method m = class_getInstanceMethod(cls, sel);
    const char *types = m ? method_getTypeEncoding(m) : 0;
    if (!types && recv) {
        NSMethodSignature *ms = [recv methodSignatureForSelector:sel];
        if (ms) types = encoding_from_signature(ms);
    }
    if (!types) {
        fprintf(stderr, "objc: no signature for -[%s %s], assuming integer arguments\n", class_getName(cls), sel_getName(sel));
        types = "@@:qqqq";
    }
    const Sig *s = sig_parse(types);
    if (!s) s = sig_parse("@@:qqqq");
    os_unfair_lock_lock(&sig_lock);
    for (uint64_t k = h;; k = (k + 1) % SIGCACHE)
        if (!sigcache[k].cls || (sigcache[k].cls == cls && sigcache[k].sel == sel)) { sigcache[k] = (SigEntry){cls, sel, s}; break; }
    os_unfair_lock_unlock(&sig_lock);
    return s;
}

// ---------- variadic selectors ----------
static int send_variadic(CPU *c, id recv, SEL sel) {
    if (sel == @selector(stringWithFormat:)) {
        NSString *fmt = (NSString *)C.rdx;
        uint64_t slots[64]; GuestVA g = gva_regs(c, 3);
        if (!gva_pack_printf(&g, fmt.UTF8String, 0, slots, 64)) unimpl_import(c, "stringWithFormat: format");
        C.rax = (uint64_t)[[[recv alloc] initWithFormat:fmt arguments:slots_va(slots)] autorelease];
        return 1;
    }
    if (sel == @selector(arrayWithObjects:)) {
        id objs[256]; int n = 0;
        objs[n++] = (id)C.rdx;
        GuestVA g = gva_regs(c, 3);
        if (objs[0]) while (n < 256 && (objs[n] = (id)gva_int(&g))) n++;
        if (!objs[n - 1]) n--;
        C.rax = (uint64_t)[recv arrayWithObjects:objs count:n];
        return 1;
    }
    return 0;
}

// ---------- message sends from guest code ----------
void rt_main_drain(void);
void rt_main_sync(void (*fn)(void *), void *ctx);
int rt_needs_main(id recv, SEL sel);

typedef struct { CPU *c; const Sig *s; void *fn; int skip; } Send;
static void send_on_main(void *p) { Send *m = p; sig_call_native(m->c, m->s, m->fn, m->skip); }

void rt_blit_frame(void);
// diagnostics: RT_FPS=1 prints presented frames per second; RT_NOVSYNC=1 forces swap interval 0
static int fps_on = -1, novsync = -1;
static void frame_presented(void) {
    static uint64_t frames, t0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (!t0) t0 = now;
    frames++;
    if (now - t0 >= 2000000000ull) {
        fprintf(stderr, "fps: %.1f\n", frames * 1e9 / (now - t0));
        frames = 0; t0 = now;
    }
}

static void gl_surface_1x(void *v) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)((id)v, sel_registerName("setWantsBestResolutionOpenGLSurface:"), NO);
}

// selectors whose geometry is converted between the game's units and points (see send)
enum { G_ARG_RECT = 1, G_ARG_POINT = 2, G_RET_RECT = 4, G_RET_POINT = 8, G_RET_SCALAR = 16 };
static int geometry_kind(SEL sel) {
    static SEL r_rect[4], a_rect[5], a_rect_r_rect[2], p_both[5], r_point[2], r_scalar[2], a_point[2], init_rect[4];
    static int init;
    if (!init) {
        r_rect[0] = @selector(frame); r_rect[1] = @selector(visibleFrame); r_rect[2] = @selector(bounds); r_rect[3] = @selector(contentLayoutRect);
        a_rect[0] = @selector(setFrame:display:); a_rect[1] = @selector(setFrame:display:animate:); a_rect[2] = @selector(setFrame:);
        a_rect[3] = @selector(setContentSize:); a_rect[4] = @selector(setFrameSize:);
        a_rect_r_rect[0] = @selector(contentRectForFrameRect:); a_rect_r_rect[1] = @selector(frameRectForContentRect:);
        p_both[0] = @selector(convertPoint:fromView:); p_both[1] = @selector(convertPoint:toView:);
        p_both[2] = @selector(convertBaseToScreen:); p_both[3] = @selector(convertScreenToBase:); p_both[4] = NULL;
        r_point[0] = @selector(locationInWindow); r_point[1] = @selector(mouseLocation);
        r_scalar[0] = @selector(deltaX); r_scalar[1] = @selector(deltaY);
        a_point[0] = @selector(setFrameOrigin:); a_point[1] = @selector(setFrameTopLeftPoint:);
        init_rect[0] = @selector(initWithContentRect:styleMask:backing:defer:);
        init_rect[1] = @selector(initWithContentRect:styleMask:backing:defer:screen:);
        init_rect[2] = @selector(initWithFrame:); init_rect[3] = @selector(initWithFrame:pixelFormat:);
        init = 1;
    }
    for (int k = 0; k < 4; k++) if (sel == r_rect[k]) return G_RET_RECT;
    for (int k = 0; k < 3; k++) if (sel == a_rect[k]) return G_ARG_RECT;
    if (sel == a_rect[3] || sel == a_rect[4]) return G_ARG_POINT;    // NSSize: two doubles in xmm0/xmm1
    for (int k = 0; k < 2; k++) if (sel == a_rect_r_rect[k]) return G_ARG_RECT | G_RET_RECT;
    for (int k = 0; k < 4; k++) if (sel == p_both[k]) return G_ARG_POINT | G_RET_POINT;
    for (int k = 0; k < 2; k++) if (sel == r_point[k]) return G_RET_POINT;
    for (int k = 0; k < 2; k++) if (sel == r_scalar[k]) return G_RET_SCALAR;
    for (int k = 0; k < 2; k++) if (sel == a_point[k]) return G_ARG_POINT;
    for (int k = 0; k < 4; k++) if (sel == init_rect[k]) return G_ARG_RECT;
    return 0;
}

// AppKit calls that must run on the main thread are performed there with the caller's registers
static void send(CPU *c, id recv, SEL sel, const Sig *s, void *fn, int skip) {
    if (fps_on < 0) { fps_on = getenv("RT_FPS") != 0; novsync = getenv("RT_NOVSYNC") != 0; }
    {   // RT_LOG_GEOMETRY=1: which objects the game asks for sizes and positions
        static int geo = -1;
        if (geo < 0) geo = getenv("RT_LOG_GEOMETRY") != 0;
        if (geo) {
            const char *sn = sel_getName(sel);
            if (!strcmp(sn, "frame") || !strcmp(sn, "bounds") || !strcmp(sn, "visibleFrame") || !strcmp(sn, "convertRectToBacking:") ||
                !strcmp(sn, "backingScaleFactor") || !strcmp(sn, "locationInWindow") || !strcmp(sn, "convertPoint:fromView:") ||
                !strcmp(sn, "setFrame:display:") || !strcmp(sn, "mouseLocationOutsideOfEventStream") || !strcmp(sn, "contentRectForFrameRect:")) {
                static char seen[64][96];
                static int nseen;
                char key[96];
                snprintf(key, sizeof key, "%s %s", class_getName(object_getClass(recv)), sn);
                int k;
                for (k = 0; k < nseen; k++) if (!strcmp(seen[k], key)) break;
                if (k == nseen && nseen < 64) { strcpy(seen[nseen++], key); fprintf(stderr, "geometry: [%s]\n", key); }
            }
        }
    }
    {   // RT_LOG_SEND=word,word: log messages whose selector contains one of the words
        static char *words = (char *)-1;
        if (words == (char *)-1) words = getenv("RT_LOG_SEND");
        if (words) {
            const char *sn = sel_getName(sel);
            char buf[256]; snprintf(buf, sizeof buf, "%s", words);
            char *save;
            for (char *w = strtok_r(buf, ",", &save); w; w = strtok_r(NULL, ",", &save))
                if (strstr(sn, w)) {
                    double *a = (double *)(C.rsp + 8);
                    fprintf(stderr, "send: [%s %s] rdx=%llx rcx=%llx r8=%llx xmm0=%g xmm1=%g stack=%g %g %g %g\n",
                            class_getName(object_getClass(recv)), sn, (unsigned long long)C.rdx, (unsigned long long)C.rcx,
                            (unsigned long long)C.r8, C.xmm[0].d[0], C.xmm[1].d[0], a[0], a[1], a[2], a[3]);
                    break;
                }
        }
    }
    if (sel == @selector(flushBuffer)) { if (fps_on) frame_presented(); rt_glcount_frame(); rt_blit_frame(); }
    if (novsync && sel == @selector(setValues:forParameter:) && (NSInteger)C.rcx == 222)   // NSOpenGLContextParameterSwapInterval
        wr32(C.rdx, 0);
    // the app is Retina-capable (for the Metal renderer's native drawable); keep Apple GL's surface at 1x
    if (!rt_metal && sel == @selector(setView:) && [recv isKindOfClass:NSClassFromString(@"NSOpenGLContext")]) {
        id v = (id)C.rdx;
        if ([v respondsToSelector:sel_registerName("setWantsBestResolutionOpenGLSurface:")]) rt_main_sync(gl_surface_1x, (void *)v);
    }
    if (rt_metal && (sel == @selector(init) || sel == @selector(release) || sel == @selector(drain))) {
        static Class arp;
        if (!arp) arp = NSClassFromString(@"NSAutoreleasePool");
        if (object_getClass(recv) == arp) mgl_pool_yield();
    }
    // RT_SCREEN: the game's "main screen" is the chosen one, and its window is centred there
    if (sel == @selector(mainScreen) && recv == (id)NSClassFromString(@"NSScreen")) { C.rax = (uint64_t)rt_screen(); return; }
    if (sel == @selector(center) && rt_screen_chosen() && [recv isKindOfClass:NSClassFromString(@"NSWindow")]) {
        mgl_center_window(recv);
        return;
    }
    if (rt_metal && [recv isKindOfClass:NSClassFromString(@"NSOpenGLContext")]) {   // the Metal renderer owns presentation
        if (sel == @selector(setView:)) { mgl_set_view((void *)C.rdx); return; }
        if (sel == @selector(flushBuffer)) { mgl_present(); return; }
        if (sel == @selector(setValues:forParameter:)) {
            if ((NSInteger)C.rcx == 222) mgl_set_swap_interval((int)rd32(C.rdx));
            return;
        }
        if (sel == @selector(makeCurrentContext) || sel == @selector(update) || sel == @selector(clearDrawable)) return;
    }
    // Render scale (Metal on Retina, see mgl_view_scale): the game works in units of points x scale. Geometry
    // it passes to AppKit is divided by the scale, geometry AppKit returns to it is multiplied; messages
    // handled by the game's own classes (which pass them on to AppKit) are left alone.
    double gs = rt_metal ? mgl_view_scale() : 1.0;
    int geo = 0;
    uint64_t ret_ptr = skip ? C.rdi : 0;
    if (gs != 1.0) geo = geometry_kind(sel);
    if (geo) {
        Class cls = fn == (void *)objc_msgSendSuper ? ((struct objc_super *)C.rdi)->super_class : object_getClass(recv);
        if (is_guest_imp(class_getMethodImplementation(cls, sel))) geo = 0;
    }
    if (geo & G_ARG_RECT) { double *r = (double *)(C.rsp + 8); for (int k = 0; k < 4; k++) r[k] /= gs; }
    // Before entering fullscreen the game sizes its window to the screen plus a title bar; AppKit then
    // shrinks it to the visible frame, and the game takes that resize (not fullscreen) as a request to
    // leave fullscreen, which it enters again, and so on. Fit the window to the visible frame up front.
    if (rt_metal && mgl_game_fullscreen() && (sel == @selector(setFrame:display:) || sel == @selector(setFrame:display:animate:)) &&
        [recv isKindOfClass:NSClassFromString(@"NSWindow")] &&
        !(((NSUInteger (*)(id, SEL))objc_msgSend)(recv, sel_registerName("styleMask")) & (1 << 14))) {   // NSWindowStyleMaskFullScreen
        double *r = (double *)(C.rsp + 8);
        id screen = (id)rt_screen();
        NSRect v = ((NSRect (*)(id, SEL))objc_msgSend)(screen, sel_registerName("visibleFrame"));
        if (r[2] > v.size.width || r[3] > v.size.height) {
            if (r[2] > v.size.width) r[2] = v.size.width;
            if (r[3] > v.size.height) r[3] = v.size.height;
            r[0] = v.origin.x + (v.size.width - r[2]) / 2;
            r[1] = v.origin.y + (v.size.height - r[3]) / 2;
        }
    }
    if (geo & G_ARG_POINT) { C.xmm[0].d[0] /= gs; C.xmm[1].d[0] /= gs; }
    if (pthread_main_np()) rt_main_drain();
    if (!pthread_main_np() && rt_needs_main(recv, sel)) { Send m = {c, s, fn, skip}; rt_main_sync(send_on_main, &m); }
    else sig_call_native(c, s, fn, skip);
    // a screen's frame includes the strip beside a camera notch, which fullscreen windows stay below: report
    // the usable part, so the game centres its picture in what is actually shown
    if (rt_metal && ret_ptr && sel == @selector(frame) && [recv isKindOfClass:NSClassFromString(@"NSScreen")] &&
        [recv respondsToSelector:sel_registerName("safeAreaInsets")]) {
        typedef struct { double top, left, bottom, right; } Insets;
        Insets in = ((Insets (*)(id, SEL))objc_msgSend)(recv, sel_registerName("safeAreaInsets"));
        ((double *)ret_ptr)[3] -= in.top;
    }
    if ((geo & G_RET_RECT) && ret_ptr) { double *r = (double *)ret_ptr; for (int k = 0; k < 4; k++) r[k] *= gs; }
    if (geo && getenv("RT_LOG_GEOMETRY")) {
        double *a = (double *)(C.rsp + 8), *r = ret_ptr ? (double *)ret_ptr : NULL;
        fprintf(stderr, "geometry: [%s %s] args(rect %g %g %g %g | pt %g %g) ret(rect %g %g %g %g | pt %g %g)\n",
                class_getName(object_getClass(recv)), sel_getName(sel), (geo & G_ARG_RECT) ? a[0] : 0, (geo & G_ARG_RECT) ? a[1] : 0,
                (geo & G_ARG_RECT) ? a[2] : 0, (geo & G_ARG_RECT) ? a[3] : 0, C.xmm[0].d[0], C.xmm[1].d[0],
                r ? r[0] : 0, r ? r[1] : 0, r ? r[2] : 0, r ? r[3] : 0, C.xmm[0].d[0] * ((geo & G_RET_POINT) ? 1 : 0), C.xmm[1].d[0]);
    }
    if (geo & G_RET_POINT) { C.xmm[0].d[0] *= gs; C.xmm[1].d[0] *= gs; }
    if (geo & G_RET_SCALAR) C.xmm[0].d[0] *= gs;
}

void I__objc_msgSend(CPU *c) {
    id recv = (id)C.rdi;
    SEL sel = (SEL)C.rsi;
    if (!recv) { C.rax = C.rdx = 0; memset(&C.xmm[0], 0, 32); RET(); return; }
    if (!send_variadic(c, recv, sel))
        send(c, recv, sel, sig_for(recv, object_getClass(recv), sel), (void *)objc_msgSend, 0);
    RET();
}

void I__objc_msgSend_stret(CPU *c) {
    id recv = (id)C.rsi;
    SEL sel = (SEL)C.rdx;
    if (!recv) { C.rax = C.rdi; RET(); return; }       // result buffer left as the caller set it
    const Sig *s = sig_for(recv, object_getClass(recv), sel);
    uint64_t result = C.rdi;
    // the arguments are self, _cmd, ... starting at rsi: skip rdi (result pointer)
    send(c, recv, sel, s, (void *)objc_msgSend, 1);
    (void)result;
    RET();
}

void I__objc_msgSendSuper2(CPU *c) {
    struct objc_super *sup = (struct objc_super *)C.rdi;   // { receiver, current class }
    SEL sel = (SEL)C.rsi;
    Class start = class_getSuperclass(sup->super_class);
    const Sig *s = sig_for(sup->receiver, start, sel);
    // objc_msgSendSuper (not Super2) takes { receiver, class to start searching from }
    struct objc_super host = {sup->receiver, start};
    uint64_t saved = C.rdi;
    C.rdi = (uint64_t)&host;
    send(c, sup->receiver, sel, s, (void *)objc_msgSendSuper, 0);
    (void)saved;
    RET();
}
