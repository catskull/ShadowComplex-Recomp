// Opt-in OpenGL trace for rendering investigations (RT_GLTRACE=1). Wraps texture/framebuffer setup
// calls and logs each distinct depth-texture format, texture parameter, framebuffer attachment and
// polygon offset once; shaders mentioning shadows are saved to $RT_GLTRACE_DIR (default /tmp/scr-shaders).
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/gl3.h>
#import <OpenGL/gl3ext.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "rt.h"

#define RET() (C.rsp += 8)

// Metal renderer entry points (mgl.m)
void mgl_glTexImage2D(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
void mgl_glTexParameteri(GLenum, GLenum, GLint);
void mgl_glFramebufferTexture2D(GLenum, GLenum, GLenum, GLuint, GLint);
void mgl_glPolygonOffset(GLfloat, GLfloat);
void mgl_glBlitFramebuffer(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
void mgl_glRenderbufferStorage(GLenum, GLenum, GLsizei, GLsizei);
void mgl_glRenderbufferStorageMultisample(GLenum, GLsizei, GLenum, GLsizei, GLsizei);
void mgl_glFramebufferRenderbuffer(GLenum, GLenum, GLenum, GLuint);
void mgl_glDrawArrays(GLenum, GLint, GLsizei);
void mgl_glDrawRangeElements(GLenum, GLuint, GLuint, GLsizei, GLenum, const void *);
void mgl_glBindFramebuffer(GLenum, GLuint);
void mgl_glClear(GLbitfield);
void mgl_glDrawArraysInstancedARB(GLenum, GLint, GLsizei, GLsizei);
void mgl_glDrawElementsInstancedARB(GLenum, GLsizei, GLenum, const void *, GLsizei);
void mgl_glEnd(void);
void mgl_glShaderSource(GLuint, GLsizei, const GLchar *const *, const GLint *);

static int tracing(void) {
    static int on = -1;
    if (on < 0) on = getenv("RT_GLTRACE") != 0;
    return on;
}

// log a line only the first time it is seen
static void once(const char *line) {
    static char *seen[8192];
    static int nseen;
    for (int k = 0; k < nseen; k++) if (!strcmp(seen[k], line)) return;
    if (nseen < 8192) seen[nseen++] = strdup(line);
    fprintf(stderr, "gl: %s\n", line);
}

static int is_depth(GLenum f) {
    return f == GL_DEPTH_COMPONENT || f == GL_DEPTH_COMPONENT16 || f == GL_DEPTH_COMPONENT24 ||
           f == GL_DEPTH_COMPONENT32 || f == GL_DEPTH_COMPONENT32F || f == GL_DEPTH_STENCIL ||
           f == GL_DEPTH24_STENCIL8 || f == GL_DEPTH32F_STENCIL8;
}

// ---------- full-precision scene colour (opt-in experiment: RT_FULL_SCENE=1) ----------
// The game keeps scene depth in the alpha channel of RGBA16F render targets and rebuilds world
// positions from it to project shadows. At half precision a floor seen at a grazing angle gets
// depth steps big enough to fall below the surface, which shows as black horizontal streaks under
// the flashlight. Allocate those targets as RGBA32F instead (Apple GPUs render and filter it).
// This did not cure the streaks (see fix_shader), so it stays off by default.
#define MAX_TEX 65536
static uint32_t gen_tex[65536], gen_rb[65536];   // write generations (redundant blit elimination)
static void fbo_attach(GLenum target, GLenum attachment, int rb, GLuint name);
// legacy-profile entry points the game uses (not declared by gl3.h)
extern void glDrawArraysInstancedARB(GLenum, GLint, GLsizei, GLsizei);
extern void glDrawElementsInstancedARB(GLenum, GLsizei, GLenum, const void *, GLsizei);
extern void glEnd(void);
static uint8_t is_r32f[MAX_TEX];     // shadow maps, for the RT_SHADOWDUMP capture
static GLuint bound_tex(void) { GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t); return (GLuint)t; }
static GLint promote(GLint f) {
    static int full = -1;
    if (full < 0) full = getenv("RT_FULL_SCENE") != 0;
    return full && f == GL_RGBA16F ? GL_RGBA32F : f;
}

// void glTexImage2D(target, level, internalformat, width, height, border, format, type, data)
void I__glTexImage2D(CPU *c) {
    GLCOUNT("glTexImage2D");
    if (rt_metal) { mgl_glTexImage2D((GLenum)C.rdi, (GLint)C.rsi, (GLint)C.rdx, (GLsizei)C.rcx, (GLsizei)C.r8, (GLint)C.r9, (GLenum)rd64s(C.rsp + 8), (GLenum)rd64s(C.rsp + 16), (const void *)rd64s(C.rsp + 24)); RET(); return; }
    GLenum target = (GLenum)C.rdi, fmt = (GLenum)rd64s(C.rsp + 8), type = (GLenum)rd64s(C.rsp + 16);
    GLint ifmt = (GLint)C.rdx;
    if (tracing()) {
        char b[160];
        snprintf(b, sizeof b, "TexImage2D level %d internalformat 0x%x format 0x%x type 0x%x (%dx%d)",
                 (int)C.rsi, ifmt, fmt, type, (int)C.rcx, (int)C.r8);
        once(b);
    }
    glTexImage2D(target, (GLint)C.rsi, promote(ifmt), (GLsizei)C.rcx, (GLsizei)C.r8, (GLint)C.r9, fmt, type,
                 (const void *)rd64s(C.rsp + 24));
    { GLuint t = bound_tex(); if (target == GL_TEXTURE_2D && t < 65536) gen_tex[t]++; }
    if (target == GL_TEXTURE_2D && ifmt == GL_R32F) {
        GLuint t = bound_tex();
        if (t < MAX_TEX) is_r32f[t] = 1;
    }
    RET();
}

void I__glTexParameteri(CPU *c) {
    GLCOUNT("glTexParameteri");
    if (rt_metal) { mgl_glTexParameteri((GLenum)C.rdi, (GLenum)C.rsi, (GLint)C.rdx); RET(); return; }
    GLenum target = (GLenum)C.rdi, pname = (GLenum)C.rsi;
    GLint param = (GLint)C.rdx;
    if (tracing()) {
        char b[128];
        snprintf(b, sizeof b, "TexParameteri target 0x%x pname 0x%x param 0x%x", target, pname, param);
        once(b);
    }
    glTexParameteri(target, pname, param);
    RET();
}

void I__glFramebufferTexture2D(CPU *c) {
    GLCOUNT("glFramebufferTexture2D");
    if (rt_metal) { mgl_glFramebufferTexture2D((GLenum)C.rdi, (GLenum)C.rsi, (GLenum)C.rdx, (GLuint)C.rcx, (GLint)C.r8); RET(); return; }
    if (tracing()) {
        char b[128];
        snprintf(b, sizeof b, "FramebufferTexture2D attachment 0x%x textarget 0x%x texture %u level %d",
                 (GLenum)C.rsi, (GLenum)C.rdx, (GLuint)C.rcx, (GLint)C.r8);
        once(b);
    }
    glFramebufferTexture2D((GLenum)C.rdi, (GLenum)C.rsi, (GLenum)C.rdx, (GLuint)C.rcx, (GLint)C.r8);
    fbo_attach((GLenum)C.rdi, (GLenum)C.rsi, 0, (GLuint)C.rcx);
    RET();
}

void I__glPolygonOffset(CPU *c) {
    GLCOUNT("glPolygonOffset");
    if (rt_metal) { mgl_glPolygonOffset(C.xmm[0].f[0], C.xmm[1].f[0]); RET(); return; }
    if (tracing()) {
        char b[96];
        snprintf(b, sizeof b, "PolygonOffset factor %g units %g", C.xmm[0].f[0], C.xmm[1].f[0]);
        once(b);
    }
    glPolygonOffset(C.xmm[0].f[0], C.xmm[1].f[0]);
    RET();
}

// ---------- redundant blit elimination ----------
// UE3 resolves render targets with glBlitFramebuffer (44 per frame in gameplay). On Apple's
// GL-on-Metal every blit ends the current render pass, so each costs a full-resolution load and
// store. Track a write generation for every renderbuffer and texture (bumped by draws and clears
// into a framebuffer that has it attached, and by reallocation) and skip a blit when neither its
// source nor its destination changed since the identical blit last ran. RT_BLITSTATS=1 logs counts;
// RT_KEEPBLITS=1 performs every blit.
#define MAX_OBJ 65536
#define MAX_FBO 4096
typedef struct { uint8_t rb; uint32_t name; } Att;   // rb: 1 renderbuffer, 0 texture; name 0 = none
static Att fbo_att[MAX_FBO][2];                        // [0] colour 0, [1] depth or depth-stencil
static GLuint cur_draw_fbo, cur_read_fbo;
static uint32_t *gen_of(Att a) {
    if (!a.name || a.name >= MAX_OBJ) return NULL;
    return a.rb ? &gen_rb[a.name] : &gen_tex[a.name];
}
static void fbo_written(GLbitfield mask) {
    if (cur_draw_fbo >= MAX_FBO) return;
    uint32_t *g;
    if ((mask & GL_COLOR_BUFFER_BIT) && (g = gen_of(fbo_att[cur_draw_fbo][0]))) ++*g;
    if ((mask & (GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) && (g = gen_of(fbo_att[cur_draw_fbo][1]))) ++*g;
}
#define ALL_BITS (GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)
static void fbo_attach(GLenum target, GLenum attachment, int rb, GLuint name) {
    GLuint f = target == GL_READ_FRAMEBUFFER ? cur_read_fbo : cur_draw_fbo;
    if (f >= MAX_FBO) return;
    int k = attachment == GL_COLOR_ATTACHMENT0 ? 0 :
            (attachment == GL_DEPTH_ATTACHMENT || attachment == GL_DEPTH_STENCIL_ATTACHMENT || attachment == GL_STENCIL_ATTACHMENT) ? 1 : -1;
    if (k < 0) return;
    fbo_att[f][k] = (Att){(uint8_t)rb, name};
    uint32_t *g = gen_of(fbo_att[f][k]);
    if (g) ++*g;                                       // attaching may expose different contents
}

typedef struct { Att src, dst; GLint r[8]; GLbitfield mask; GLenum filter; uint32_t gsrc, gdst; int used; } BlitRec;
#define NBLIT 256
static BlitRec blits[NBLIT];
static uint64_t blit_total, blit_skipped;
static int blit_redundant(const GLint *r, GLbitfield mask, GLenum filter, BlitRec **slot) {
    *slot = NULL;
    if (cur_read_fbo >= MAX_FBO || cur_draw_fbo >= MAX_FBO || !cur_read_fbo || !cur_draw_fbo) return 0;
    int k = mask & GL_COLOR_BUFFER_BIT ? 0 : 1;
    if (mask != GL_COLOR_BUFFER_BIT && mask != GL_DEPTH_BUFFER_BIT) return 0;   // only the plain cases
    Att src = fbo_att[cur_read_fbo][k], dst = fbo_att[cur_draw_fbo][k];
    uint32_t *gs = gen_of(src), *gd = gen_of(dst);
    if (!gs || !gd) return 0;
    unsigned h = (src.name * 31u + dst.name * 7u + src.rb * 3u + dst.rb + (unsigned)k * 101u) % NBLIT;
    BlitRec *b = &blits[h];
    *slot = b;
    return b->used && !memcmp(&b->src, &src, sizeof src) && !memcmp(&b->dst, &dst, sizeof dst) &&
           !memcmp(b->r, r, sizeof b->r) && b->mask == mask && b->filter == filter &&
           b->gsrc == *gs && b->gdst == *gd;
}
static void blit_record(BlitRec *b, const GLint *r, GLbitfield mask, GLenum filter) {
    if (!b) return;
    int k = mask & GL_COLOR_BUFFER_BIT ? 0 : 1;
    b->src = fbo_att[cur_read_fbo][k]; b->dst = fbo_att[cur_draw_fbo][k];
    memcpy(b->r, r, sizeof b->r); b->mask = mask; b->filter = filter;
    uint32_t *gd = gen_of(b->dst);
    ++*gd;                                             // the blit wrote the destination
    b->gsrc = *gen_of(b->src); b->gdst = *gd; b->used = 1;
}
void rt_blit_frame(void) {
    static int on = -1;
    static uint64_t frames;
    if (on < 0) on = getenv("RT_BLITSTATS") != 0;
    if (!on) return;
    if (++frames % 240) return;
    fprintf(stderr, "blits: %.1f per frame, %.1f skipped as unchanged\n", blit_total / 240.0, blit_skipped / 240.0);
    blit_total = blit_skipped = 0;
}

void I__glBindFramebuffer(CPU *c) {
    GLCOUNT("glBindFramebuffer");
    if (rt_metal) { mgl_glBindFramebuffer((GLenum)C.rdi, (GLuint)C.rsi); RET(); return; }
    GLenum target = (GLenum)C.rdi;
    GLuint f = (GLuint)C.rsi;
    if (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER) cur_draw_fbo = f;
    if (target == GL_FRAMEBUFFER || target == GL_READ_FRAMEBUFFER) cur_read_fbo = f;
    glBindFramebuffer(target, f);
    RET();
}
void I__glClear(CPU *c) {
    GLCOUNT("glClear");
    if (rt_metal) { mgl_glClear((GLbitfield)C.rdi); RET(); return; }
    fbo_written((GLbitfield)C.rdi);
    glClear((GLbitfield)C.rdi);
    RET();
}
void I__glDrawArraysInstancedARB(CPU *c) {
    GLCOUNT("glDrawArraysInstancedARB");
    if (rt_metal) { mgl_glDrawArraysInstancedARB((GLenum)C.rdi, (GLint)C.rsi, (GLsizei)C.rdx, (GLsizei)C.rcx); RET(); return; }
    fbo_written(ALL_BITS);
    glDrawArraysInstancedARB((GLenum)C.rdi, (GLint)C.rsi, (GLsizei)C.rdx, (GLsizei)C.rcx);
    RET();
}
void I__glDrawElementsInstancedARB(CPU *c) {
    GLCOUNT("glDrawElementsInstancedARB");
    if (rt_metal) { mgl_glDrawElementsInstancedARB((GLenum)C.rdi, (GLsizei)C.rsi, (GLenum)C.rdx, (const void *)C.rcx, (GLsizei)C.r8); RET(); return; }
    fbo_written(ALL_BITS);
    glDrawElementsInstancedARB((GLenum)C.rdi, (GLsizei)C.rsi, (GLenum)C.rdx, (const void *)C.rcx, (GLsizei)C.r8);
    RET();
}
void I__glEnd(CPU *c) {
    GLCOUNT("glEnd");
    if (rt_metal) { mgl_glEnd(); RET(); return; }
    fbo_written(ALL_BITS);
    glEnd();
    RET();
}

// set while an RT_SHADOWDUMP capture is running; each framebuffer resolved by a blit is saved once
static int capturing, blit_seq, target_blits, trace_fbo = -1;
static uint8_t blit_done[4096];
static void dump_read_fbo(GLint fbo, int w, int h) {
    if (w <= 0 || h <= 0 || fbo < 0 || fbo >= 4096 || blit_done[fbo]) return;
    blit_done[fbo] = 1;
    float *px = malloc((size_t)w * h * 4 * sizeof(float));
    glReadPixels(0, 0, w, h, GL_RGBA, GL_FLOAT, px);
    long nan = 0, inf = 0, neg = 0;
    for (long k = 0; k < (long)w * h * 4; k++) { float v = px[k]; nan += isnan(v); inf += isinf(v); neg += v < 0; }
    char path[600];
    snprintf(path, sizeof path, "%s/sc-shadow/blit%02d_fbo%d.rgba", getenv("HOME"), blit_seq++, fbo);
    FILE *f = fopen(path, "wb");
    if (f) { fprintf(f, "RGBA %d %d\n", w, h); fwrite(px, sizeof(float) * 4, (size_t)w * h, f); fclose(f); }
    fprintf(stderr, "shadowdump: blit source fbo %d (%dx%d): nan %ld inf %ld neg %ld -> %s\n", fbo, w, h, nan, inf, neg, path);
    free(px);
}

// void glBlitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)
void I__glBlitFramebuffer(CPU *c) {
    GLCOUNT("glBlitFramebuffer");
    if (rt_metal) { mgl_glBlitFramebuffer((GLint)C.rdi, (GLint)C.rsi, (GLint)C.rdx, (GLint)C.rcx, (GLint)C.r8, (GLint)C.r9, (GLint)rd64s(C.rsp + 8), (GLint)rd64s(C.rsp + 16), (GLbitfield)rd64s(C.rsp + 24), (GLenum)rd64s(C.rsp + 32)); RET(); return; }
    GLint s[10] = {(GLint)C.rdi, (GLint)C.rsi, (GLint)C.rdx, (GLint)C.rcx, (GLint)C.r8, (GLint)C.r9,
                   (GLint)rd64s(C.rsp + 8), (GLint)rd64s(C.rsp + 16), (GLint)rd64s(C.rsp + 24), (GLint)rd64s(C.rsp + 32)};
    if (tracing()) {
        GLint rf = 0, df = 0, rt = 0, rn = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &rf); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &df);
        glBindFramebuffer(GL_FRAMEBUFFER, rf);
        glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &rt);
        glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &rn);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, rf); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, df);
        char b[200];
        snprintf(b, sizeof b, "BlitFramebuffer fbo %d (color0 %s %d) -> fbo %d  src %d,%d-%d,%d dst %d,%d-%d,%d mask 0x%x filter 0x%x",
                 rf, rt == GL_RENDERBUFFER ? "rb" : rt == GL_TEXTURE ? "tex" : "-", rn, df,
                 s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9]);
        once(b);
        GLenum e = glGetError();
        if (e) { snprintf(b, sizeof b, "GL error 0x%x before blit", e); once(b); }
    }
    static int keep = -1;
    if (keep < 0) keep = getenv("RT_KEEPBLITS") != 0;
    BlitRec *rec;
    blit_total++;
    if (!keep && !capturing && blit_redundant(s, (GLbitfield)s[8], (GLenum)s[9], &rec)) { blit_skipped++; RET(); return; }
    glBlitFramebuffer(s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], (GLbitfield)s[8], (GLenum)s[9]);
    blit_record(rec, s, (GLbitfield)s[8], (GLenum)s[9]);
    if (capturing && (s[8] & GL_COLOR_BUFFER_BIT)) {
        GLint rf = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &rf);
        dump_read_fbo(rf, s[2] - s[0], s[3] - s[1]);
        if (rf == trace_fbo) target_blits++;
    }
    if (tracing()) {
        GLenum e = glGetError();
        if (e) { char b[64]; snprintf(b, sizeof b, "GL error 0x%x from blit", e); once(b); }
    }
    RET();
}

// void glRenderbufferStorage(target, internalformat, width, height)
void I__glRenderbufferStorage(CPU *c) {
    GLCOUNT("glRenderbufferStorage");
    if (rt_metal) { mgl_glRenderbufferStorage((GLenum)C.rdi, (GLenum)C.rsi, (GLsizei)C.rdx, (GLsizei)C.rcx); RET(); return; }
    if (tracing()) {
        char b[128];
        snprintf(b, sizeof b, "RenderbufferStorage internalformat 0x%x (%dx%d)", (GLenum)C.rsi, (int)C.rdx, (int)C.rcx);
        once(b);
    }
    glRenderbufferStorage((GLenum)C.rdi, promote((GLenum)C.rsi), (GLsizei)C.rdx, (GLsizei)C.rcx);
    { GLint rb = 0; glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb); if (rb > 0 && rb < MAX_OBJ) gen_rb[rb]++; }
    RET();
}
// void glRenderbufferStorageMultisample(target, samples, internalformat, width, height)
void I__glRenderbufferStorageMultisample(CPU *c) {
    GLCOUNT("glRenderbufferStorageMultisample");
    if (rt_metal) { mgl_glRenderbufferStorageMultisample((GLenum)C.rdi, (GLsizei)C.rsi, (GLenum)C.rdx, (GLsizei)C.rcx, (GLsizei)C.r8); RET(); return; }
    if (tracing()) {
        char b[128];
        snprintf(b, sizeof b, "RenderbufferStorageMultisample samples %d internalformat 0x%x (%dx%d)",
                 (int)C.rsi, (GLenum)C.rdx, (int)C.rcx, (int)C.r8);
        once(b);
    }
    glRenderbufferStorageMultisample((GLenum)C.rdi, (GLsizei)C.rsi, promote((GLenum)C.rdx), (GLsizei)C.rcx, (GLsizei)C.r8);
    RET();
}
void I__glFramebufferRenderbuffer(CPU *c) {
    GLCOUNT("glFramebufferRenderbuffer");
    if (rt_metal) { mgl_glFramebufferRenderbuffer((GLenum)C.rdi, (GLenum)C.rsi, (GLenum)C.rdx, (GLuint)C.rcx); RET(); return; }
    if (tracing()) {
        char b[128];
        snprintf(b, sizeof b, "FramebufferRenderbuffer attachment 0x%x renderbuffer %u", (GLenum)C.rsi, (GLuint)C.rcx);
        once(b);
    }
    glFramebufferRenderbuffer((GLenum)C.rdi, (GLenum)C.rsi, (GLenum)C.rdx, (GLuint)C.rcx);
    fbo_attach((GLenum)C.rdi, (GLenum)C.rsi, 1, (GLuint)C.rcx);
    RET();
}

// The game's GLSL is translated from D3D9 shader assembly, where rsq takes the absolute value of
// its operand. GLSL inversesqrt of a negative number is NaN, which Apple GPUs draw as black (e.g.
// normal-map z = sqrt(1 - x*x - y*y) dipping below zero on shiny surfaces). Rewrite every
// inversesqrt(e) as inversesqrt(abs(e)) unless RT_NO_SHADERFIX is set. Returns a malloc'd string.
static char *fix_shader(const char *src) {
    static const char key[] = "inversesqrt(";
    size_t n = strlen(src), extra = 0;
    for (const char *q = src; (q = strstr(q, key)); q += sizeof key - 1) extra += 5;
    char *out = malloc(n + extra + 1), *o = out;
    const char *q = src;
    for (const char *hit; (hit = strstr(q, key)); ) {
        hit += sizeof key - 1;
        memcpy(o, q, hit - q); o += hit - q;
        const char *e = hit;
        for (int depth = 0; *e && (depth || *e != ')'); e++) depth += (*e == '(') - (*e == ')');
        memcpy(o, "abs(", 4); o += 4;
        memcpy(o, hit, e - hit); o += e - hit;
        *o++ = ')';
        q = e;
    }
    strcpy(o, q);
    return out;
}

// D3D guarantees that identical vertex maths gives bit-identical positions in every shader; GLSL
// only does for outputs declared invariant. UE3 draws each light as another pass over the scene
// with an exact depth test against the base pass, and Apple's compiler rounds the two shaders'
// positions differently, so light passes miss pixels: horizontal streaks of unlit floor at grazing
// angles. Declare gl_Position invariant in every vertex shader (after the leading # directives).
static char *invariant_position(char *src) {
    if (!strstr(src, "gl_Position") || strstr(src, "invariant gl_Position")) return src;
    const char *at = src;
    for (const char *line = src; *line; ) {
        const char *s2 = line;
        while (*s2 == ' ' || *s2 == '\t') s2++;
        const char *end = strchr(line, '\n');
        if (*s2 == '#') at = end ? end + 1 : line + strlen(line);
        else if (*s2 != '\n' && *s2 != '\r' && *s2) break;
        if (!end) break;
        line = end + 1;
    }
    static const char decl[] = "invariant gl_Position;\n";
    size_t n = strlen(src), head = at - src;
    char *out = malloc(n + sizeof decl);
    memcpy(out, src, head);
    memcpy(out + head, decl, sizeof decl - 1);
    strcpy(out + head + sizeof decl - 1, src + head);
    free(src);
    return out;
}

// void glShaderSource(GLuint shader, GLsizei count, const GLchar *const *string, const GLint *length)
void I__glShaderSource(CPU *c) {
    GLCOUNT("glShaderSource");
    GLuint sh = (GLuint)C.rdi;
    GLsizei count = (GLsizei)C.rsi;
    const GLchar *const *str = (const GLchar *const *)C.rdx;
    const GLint *len = (const GLint *)C.rcx;
    size_t total = 0;
    for (GLsizei k = 0; k < count; k++) total += len && len[k] >= 0 ? (size_t)len[k] : strlen(str[k]);
    char *src = malloc(total + 1), *p = src;
    for (GLsizei k = 0; k < count; k++) {
        size_t n = len && len[k] >= 0 ? (size_t)len[k] : strlen(str[k]);
        memcpy(p, str[k], n); p += n;
    }
    *p = 0;
    if (!getenv("RT_NO_SHADERFIX")) { char *fixed = fix_shader(src); free(src); src = fixed; }
    if (!getenv("RT_NO_INVARIANT")) src = invariant_position(src);
    if (tracing() && (getenv("RT_GLTRACE_ALL") || strstr(src, "hadow"))) {
        static int n;
        const char *dir = getenv("RT_GLTRACE_DIR") ? getenv("RT_GLTRACE_DIR") : "/tmp/scr-shaders";
        mkdir(dir, 0755);
        char path[512];
        snprintf(path, sizeof path, "%s/shader_%04d_%u.glsl", dir, n++, sh);
        FILE *f = fopen(path, "w");
        if (f) { fputs(src, f); fclose(f); }
    }
    const GLchar *one = src;
    if (rt_metal) mgl_glShaderSource(sh, 1, &one, NULL);
    else glShaderSource(sh, 1, &one, NULL);
    free(src);
    RET();
}

// ---------- incomplete-texture detector (trace mode) ----------
// Apple's GL-on-Metal samples an incomplete texture as all zeros. Before each draw, check every
// bound 2D texture against its filter and mip range, and log the first problem per texture.
static int uses_mips(GLint f) { return f != GL_NEAREST && f != GL_LINEAR; }

static void check_bound_textures(const char *call) {
    GLint active = 0, prog = 0;
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    for (int u = 0; u < 16; u++) {
        glActiveTexture(GL_TEXTURE0 + u);
        GLint tex = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
        if (!tex) continue;
        GLint minf = 0, base = 0, maxl = 0, w0 = 0, h0 = 0, ifmt = 0;
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &minf);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, &base);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, &maxl);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, base, GL_TEXTURE_WIDTH, &w0);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, base, GL_TEXTURE_HEIGHT, &h0);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, base, GL_TEXTURE_INTERNAL_FORMAT, &ifmt);
        char why[96] = "";
        if (!w0) snprintf(why, sizeof why, "base level %d undefined", base);
        else if (uses_mips(minf)) {
            int w = w0, h = h0;
            for (int l = base + 1; l <= maxl && (w > 1 || h > 1); l++) {
                w = w > 1 ? w / 2 : 1; h = h > 1 ? h / 2 : 1;
                GLint lw = 0, lh = 0;
                glGetTexLevelParameteriv(GL_TEXTURE_2D, l, GL_TEXTURE_WIDTH, &lw);
                glGetTexLevelParameteriv(GL_TEXTURE_2D, l, GL_TEXTURE_HEIGHT, &lh);
                if (lw != w || lh != h) { snprintf(why, sizeof why, "mip level %d is %dx%d, expected %dx%d", l, lw, lh, w, h); break; }
            }
        }
        if (why[0]) {
            char b[256];
            snprintf(b, sizeof b, "INCOMPLETE texture %d on unit %d (%s, program %d): %dx%d fmt 0x%x minfilter 0x%x base %d max %d: %s",
                     tex, u, call, prog, w0, h0, ifmt, minf, base, maxl, why);
            once(b);
        }
    }
    glActiveTexture(active);
}

// ---------- shadow map capture (RT_SHADOWDUMP=1) ----------
// While the game runs, `touch ~/sc-dump` and the next draws save every distinct R32F texture they
// sample (the shadow maps) to ~/sc-shadow/tex<id>.pfm, with value statistics printed to the log.
static void dump_r32f(GLuint tex, GLint prog) {
    GLint w = 0, h = 0;
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &w);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &h);
    if (w <= 0 || h <= 0) return;
    float *px = malloc((size_t)w * h * sizeof(float));
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_FLOAT, px);
    float lo = INFINITY, hi = -INFINITY;
    long nan = 0, inf = 0, neg = 0, zero = 0, big = 0;
    for (long k = 0; k < (long)w * h; k++) {
        float v = px[k];
        if (isnan(v)) { nan++; continue; }
        if (isinf(v)) { inf++; continue; }
        if (v < lo) lo = v;
        if (v > hi) hi = v;
        neg += v < 0; zero += v == 0; big += v > 1;
    }
    char dir[512], path[600];
    snprintf(dir, sizeof dir, "%s/sc-shadow", getenv("HOME"));
    mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/tex%u_prog%d.pfm", dir, tex, prog);
    FILE *f = fopen(path, "wb");
    if (f) { fprintf(f, "Pf\n%d %d\n-1.0\n", w, h); fwrite(px, sizeof(float), (size_t)w * h, f); fclose(f); }
    fprintf(stderr, "shadowdump: tex %u (%dx%d) program %d: min %g max %g  nan %ld inf %ld neg %ld zero %ld >1 %ld -> %s\n",
            tex, w, h, prog, lo, hi, nan, inf, neg, zero, big, path);
    free(px);
}

// save all four channels of a float colour texture as ~/sc-shadow/tex<id>.rgba (header line, then floats)
static void dump_rgba(GLuint tex, GLint w, GLint h) {
    if (w <= 0 || h <= 0) return;
    float *px = malloc((size_t)w * h * 4 * sizeof(float));
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_FLOAT, px);
    char path[600];
    snprintf(path, sizeof path, "%s/sc-shadow/tex%u.rgba", getenv("HOME"), tex);
    FILE *f = fopen(path, "wb");
    if (f) { fprintf(f, "RGBA %d %d\n", w, h); fwrite(px, sizeof(float) * 4, (size_t)w * h, f); fclose(f); }
    fprintf(stderr, "shadowdump:   saved %s\n", path);
    free(px);
}

static void shadow_dump_check(void) {
    static int on = -1, armed;
    static unsigned tick, left;
    static uint8_t done[MAX_TEX], done_prog[MAX_TEX];
    if (on < 0) on = getenv("RT_SHADOWDUMP") != 0;
    if (!on) return;
    char trig[512];
    snprintf(trig, sizeof trig, "%s/sc-dump", getenv("HOME"));
    if (!armed && (++tick & 1023) == 0 && !unlink(trig)) {
        armed = 1; left = 20000; memset(done, 0, sizeof done); memset(done_prog, 0, sizeof done_prog);
        capturing = 1; blit_seq = 0; target_blits = 0; memset(blit_done, 0, sizeof blit_done);
        { char d[512]; snprintf(d, sizeof d, "%s/sc-shadow", getenv("HOME")); mkdir(d, 0755); }
        fprintf(stderr, "shadowdump: capturing\n");
    }
    if (!armed) return;
    if (!--left) { armed = 0; capturing = 0; fprintf(stderr, "shadowdump: done\n"); return; }
    GLint active = 0, prog = 0;
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    GLint bound[16] = {0};
    int any = 0;
    for (int u = 0; u < 16; u++) {
        glActiveTexture(GL_TEXTURE0 + u);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound[u]);
        if (bound[u] > 0 && bound[u] < MAX_TEX && is_r32f[bound[u]]) any = 1;
    }
    if (any && prog > 0 && prog < MAX_TEX && !done_prog[prog]) {
        // a draw that samples a shadow map: describe every bound texture and save the program source
        done_prog[prog] = 1;
        GLint fbo = 0, fbt = 0, fbn = 0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbo);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &fbt);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &fbn);
        fprintf(stderr, "shadowdump: program %d draws into fbo %d (color0 %s %d)\n", prog, fbo,
                fbt == GL_RENDERBUFFER ? "rb" : fbt == GL_TEXTURE ? "tex" : "-", fbn);
        for (int u = 0; u < 16; u++) {
            if (bound[u] <= 0) continue;
            glActiveTexture(GL_TEXTURE0 + u);
            GLint w = 0, h = 0, f = 0, minf = 0, magf = 0;
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &w);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &h);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &f);
            glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &minf);
            glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &magf);
            fprintf(stderr, "shadowdump:   unit %d tex %d %dx%d fmt 0x%x filter 0x%x/0x%x\n", u, bound[u], w, h, f, minf, magf);
            if (bound[u] < MAX_TEX && !done[bound[u]]) {
                done[bound[u]] = 1;
                if (is_r32f[bound[u]]) dump_r32f((GLuint)bound[u], prog);
                else if (f == GL_RGBA16F || f == GL_RG16F || f == GL_RGBA32F) dump_rgba((GLuint)bound[u], w, h);
            }
        }
        GLuint sh[4]; GLsizei ns = 0;
        glGetAttachedShaders(prog, 4, &ns, sh);
        char path[600];
        snprintf(path, sizeof path, "%s/sc-shadow/prog%d.glsl", getenv("HOME"), prog);
        FILE *out = fopen(path, "w");
        for (int k = 0; out && k < ns; k++) {
            GLint len = 0;
            glGetShaderiv(sh[k], GL_SHADER_SOURCE_LENGTH, &len);
            char *src = malloc(len + 1); src[0] = 0;
            glGetShaderSource(sh[k], len + 1, NULL, src);
            fprintf(out, "// ---- shader %u\n%s\n", sh[k], src);
            free(src);
        }
        if (out) fclose(out);
    }
    glActiveTexture(active);
}

// During a capture, record one whole frame (present to present): after every draw into any
// framebuffer, save a crop of the streaked floor area (RT_DUMPRECT="x y w h" in 2880x1624 GL
// coordinates, scaled to the framebuffer's size) whenever it changed, and log the draw's program,
// framebuffer and bound textures to ~/sc-shadow/draws.txt.
static void save_program(GLint prog) {
    static uint8_t saved[MAX_TEX];
    if (prog <= 0 || prog >= MAX_TEX || saved[prog]) return;
    saved[prog] = 1;
    GLuint sh[4]; GLsizei ns = 0;
    glGetAttachedShaders(prog, 4, &ns, sh);
    char path[600];
    snprintf(path, sizeof path, "%s/sc-shadow/prog%d.glsl", getenv("HOME"), prog);
    FILE *out = fopen(path, "w");
    for (int k = 0; out && k < ns; k++) {
        GLint len = 0;
        glGetShaderiv(sh[k], GL_SHADER_SOURCE_LENGTH, &len);
        char *src = malloc(len + 1); src[0] = 0;
        glGetShaderSource(sh[k], len + 1, NULL, src);
        fprintf(out, "// ---- shader %u\n%s\n", sh[k], src);
        free(src);
    }
    if (out) fclose(out);
}

static void fbo_size(GLint *w, GLint *h) {
    GLint type = 0, name = 0;
    *w = *h = 0;
    glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
    glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
    if (type == GL_RENDERBUFFER) {
        GLint rb = 0;
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
        glBindRenderbuffer(GL_RENDERBUFFER, name);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, w);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, h);
        glBindRenderbuffer(GL_RENDERBUFFER, rb);
    } else if (type == GL_TEXTURE) {
        GLint t = bound_tex();
        glBindTexture(GL_TEXTURE_2D, name);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, w);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, h);
        glBindTexture(GL_TEXTURE_2D, t);
    }
}

// RT_DUMPPROG=<program>: during a capture, the first draw with that program saves every bound 2D
// texture, all mip levels, as ~/sc-shadow/p<prog>_unit<u>_tex<id>_mip<l>.rgba (decoded to float),
// and logs format, filters and sizes.
static void dump_program_textures(GLint prog) {
    static int want = -2, done_once;
    if (want == -2) want = getenv("RT_DUMPPROG") ? atoi(getenv("RT_DUMPPROG")) : -1;
    if (prog != want || done_once) return;
    done_once = 1;
    GLint active = 0;
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    for (int u = 0; u < 16; u++) {
        glActiveTexture(GL_TEXTURE0 + u);
        GLint t = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
        if (!t) continue;
        GLint minf = 0, magf = 0, base = 0, maxl = 0, ws = 0, wt = 0;
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &minf);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &magf);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, &base);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, &maxl);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, &ws);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, &wt);
        GLfloat minlod = 0, maxlod = 0, bias = 0, aniso = 0;
        glGetTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_MIN_LOD, &minlod);
        glGetTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LOD, &maxlod);
        glGetTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_LOD_BIAS, &bias);
        glGetTexParameterfv(GL_TEXTURE_2D, 0x84FE /* MAX_ANISOTROPY */, &aniso);
        fprintf(stderr, "shadowdump: prog %d unit %d tex %d filter 0x%x/0x%x base %d max %d lod %g..%g bias %g aniso %g wrap 0x%x/0x%x\n",
                prog, u, t, minf, magf, base, maxl, minlod, maxlod, bias, aniso, ws, wt);
        for (int l = 0; l < 16; l++) {
            GLint w = 0, h = 0, f = 0, comp = 0, csize = 0;
            glGetTexLevelParameteriv(GL_TEXTURE_2D, l, GL_TEXTURE_WIDTH, &w);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, l, GL_TEXTURE_HEIGHT, &h);
            if (w <= 0 || h <= 0) break;
            glGetTexLevelParameteriv(GL_TEXTURE_2D, l, GL_TEXTURE_INTERNAL_FORMAT, &f);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, l, GL_TEXTURE_COMPRESSED, &comp);
            if (comp) glGetTexLevelParameteriv(GL_TEXTURE_2D, l, GL_TEXTURE_COMPRESSED_IMAGE_SIZE, &csize);
            fprintf(stderr, "shadowdump:   mip %d %dx%d fmt 0x%x compressed %d bytes %d\n", l, w, h, f, comp, csize);
            if ((long)w * h > 2048L * 2048) continue;
            float *px = malloc((size_t)w * h * 4 * sizeof(float));
            glGetTexImage(GL_TEXTURE_2D, l, GL_RGBA, GL_FLOAT, px);
            char path[600];
            snprintf(path, sizeof path, "%s/sc-shadow/p%d_unit%d_tex%d_mip%d.rgba", getenv("HOME"), prog, u, t, l);
            FILE *fp = fopen(path, "wb");
            if (fp) { fprintf(fp, "RGBA %d %d\n", w, h); fwrite(px, sizeof(float) * 4, (size_t)w * h, fp); fclose(fp); }
            free(px);
        }
    }
    glActiveTexture(active);
}

static void draw_trace_after(void) {
    static int rx = -1, ry, rw, rh, seq, files;
    static uint64_t last_hash[4096];
    static FILE *idx;
    if (!capturing) {
        if (idx) { fclose(idx); idx = NULL; }
        seq = files = 0;
        return;
    }
    trace_fbo = 2;                       // the frame is presented by resolving fbo 2
    if (target_blits != 1) return;
    if (rx < 0) {
        rx = 1500; ry = 504; rw = 400; rh = 60;
        if (getenv("RT_DUMPRECT")) sscanf(getenv("RT_DUMPRECT"), "%d %d %d %d", &rx, &ry, &rw, &rh);
    }
    if (!idx) {
        char path[600];
        snprintf(path, sizeof path, "%s/sc-shadow/draws.txt", getenv("HOME"));
        idx = fopen(path, "w");
        memset(last_hash, 0, sizeof last_hash);
    }
    int n = seq++;
    GLint fbo = 0, prog = 0, w, h;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbo);
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    dump_program_textures(prog);
    fbo_size(&w, &h);
    if (fbo <= 0 || fbo >= 4096 || w <= 0 || files >= 4000) return;
    int x = rx * w / 2880, y = ry * h / 1624, cw = rw * w / 2880, ch = rh * h / 1624;
    if (cw < 1 || ch < 1) return;
    GLint rf = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &rf);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    float *px = malloc((size_t)cw * ch * 4 * sizeof(float));
    glReadPixels(x, y, cw, ch, GL_RGBA, GL_FLOAT, px);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, rf);
    uint64_t hsh = 1469598103934665603ULL;
    const uint8_t *bytes = (const uint8_t *)px;
    for (size_t k = 0; k < (size_t)cw * ch * 16; k++) hsh = (hsh ^ bytes[k]) * 1099511628211ULL;
    if (hsh != last_hash[fbo]) {
        last_hash[fbo] = hsh;
        save_program(prog);
        char path[600];
        snprintf(path, sizeof path, "%s/sc-shadow/draw%04d_fbo%d_prog%d.rgba", getenv("HOME"), n, fbo, prog);
        FILE *f = fopen(path, "wb");
        if (f) { fprintf(f, "RGBA %d %d\n", cw, ch); fwrite(px, sizeof(float) * 4, (size_t)cw * ch, f); fclose(f); }
        files++;
        if (idx) {
            fprintf(idx, "draw %d fbo %d (%dx%d) prog %d textures:", n, fbo, w, h, prog);
            GLint active = 0;
            glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
            for (int u = 0; u < 16; u++) {
                GLint t = 0;
                glActiveTexture(GL_TEXTURE0 + u);
                glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
                if (t) fprintf(idx, " %d:%d", u, t);
            }
            glActiveTexture(active);
            GLint ct = 0, cn = 0;
            glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &ct);
            glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &cn);
            fprintf(idx, "  -> %s %d\n", ct == GL_TEXTURE ? "tex" : "rb", cn);
        }
    }
    free(px);
}

void I__glDrawArrays(CPU *c) {
    GLCOUNT("glDrawArrays");
    if (rt_metal) { mgl_glDrawArrays((GLenum)C.rdi, (GLint)C.rsi, (GLsizei)C.rdx); RET(); return; }
    shadow_dump_check();
    if (tracing()) check_bound_textures("DrawArrays");
    fbo_written(ALL_BITS);
    glDrawArrays((GLenum)C.rdi, (GLint)C.rsi, (GLsizei)C.rdx);
    draw_trace_after();
    RET();
}
// void glDrawRangeElements(mode, start, end, count, type, indices)
void I__glDrawRangeElements(CPU *c) {
    GLCOUNT("glDrawRangeElements");
    if (rt_metal) { mgl_glDrawRangeElements((GLenum)C.rdi, (GLuint)C.rsi, (GLuint)C.rdx, (GLsizei)C.rcx, (GLenum)C.r8, (const void *)C.r9); RET(); return; }
    shadow_dump_check();
    if (tracing()) check_bound_textures("DrawRangeElements");
    fbo_written(ALL_BITS);
    glDrawRangeElements((GLenum)C.rdi, (GLuint)C.rsi, (GLuint)C.rdx, (GLsizei)C.rcx, (GLenum)C.r8, (const void *)C.r9);
    draw_trace_after();
    RET();
}
