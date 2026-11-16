// Metal renderer: the OpenGL subset the game uses, implemented directly on Metal (RT_METAL=1).
//
// Coordinate convention: GL keeps image row 0 at the bottom. Vertex shaders flip Y (SPIRV-Cross
// flip_vert_y), so memory row 0 of every render target still holds GL's bottom row; GL viewport and
// scissor rectangles can then be used directly as Metal origins and textures need no flipping.
// Only the final present flips the image onto the drawable.
//
// Phase 2 (core): one command buffer per frame; a render pass opens lazily for the current
// framebuffer and closes when the target changes, on blits and at present.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <MetalFX/MetalFX.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/gl3.h>
#import <OpenGL/gl3ext.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <spawn.h>
#include <unistd.h>
#include <objc/runtime.h>
#include "rt.h"
#include "mgl_shader.h"

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *);

// legacy / extension enums missing from gl3.h
#define GL_QUADS_ 0x0007
#define GL_ALPHA_TEST_ 0x0BC0
#define GL_LUMINANCE_ 0x1909
#define GL_LUMINANCE8_ 0x8040
#define GL_CLAMP_ 0x2900
#define GL_DXT1_RGB 0x83F0
#define GL_DXT1_RGBA 0x83F1
#define GL_DXT3 0x83F2
#define GL_DXT5 0x83F3
#define GL_SRGB_DXT1 0x8C4C
#define GL_SRGB_A_DXT1 0x8C4D
#define GL_SRGB_A_DXT3 0x8C4E
#define GL_SRGB_A_DXT5 0x8C4F
#define GL_MAX_ANISOTROPY_ 0x84FE
#define GL_MAX_SAMPLES_ 0x8D57
#define GL_TEXTURE_LOD_BIAS_ 0x8501

int rt_metal;                           // set at startup from RT_METAL
#define MGL_LOG(...) fprintf(stderr, "mgl: " __VA_ARGS__)
static void log_once(const char *msg) {
    static const char *seen[512];
    static int n;
    for (int k = 0; k < n; k++) if (!strcmp(seen[k], msg)) return;
    if (n < 512) seen[n++] = strdup(msg);
    MGL_LOG("%s\n", msg);
}
#define LOG_ONCE(...) do { char b_[256]; snprintf(b_, sizeof b_, __VA_ARGS__); log_once(b_); } while (0)

// ---------- objects ----------
typedef struct {
    id<MTLBuffer> mb;
    size_t size;
    uint64_t used;                      // serial of the last command buffer that read it
    void *map;
} Buf;
typedef struct {
    id<MTLTexture> mt;
    GLenum target;                      // GL_TEXTURE_2D or GL_TEXTURE_CUBE_MAP
    GLenum ifmt;
    MTLPixelFormat pf;
    int w, h, levels, maxlev_uploaded;
    GLint min_f, mag_f, wrap_s, wrap_t, base_level, max_level;
    float aniso;
    id<MTLSamplerState> samp;
    uint64_t used;
    int mask;                           // white with a varying alpha (font pages, icons): see classify_mask
} Tex;
typedef struct { id<MTLTexture> mt; GLenum ifmt; int w, h; } Rb;
typedef struct { int kind; GLuint name; int level, face; } Att;   // kind: 0 none, 1 texture, 2 renderbuffer
typedef struct { Att color[4], depth, stencil; int draw_none, read_none; } Fbo;
typedef struct { GLenum type; char *src; } Shader;
typedef struct {
    GLuint vs, fs;
    char *src[2];
    MglUniform u[128];
    int nu, bsize[2];
    uint8_t *block[2];
    int dirty[2];
    MglAttrib attrs[16];
    int nattrs;
    uint32_t attr_used;                 // vertex shader inputs (locations)
    int unit[2][16], skind[2][16], nsamp[2];
    int state;                          // 0 not linked, 1 compiling, 2 ready, 3 failed
    struct SJob *sj[2];                 // compiled stages (shared between programs)
    int bias_off;                       // fragment block offset of the per-sampler LOD bias (-1: none)
    dispatch_group_t warm;              // background pipeline warm-up
    GLuint name;
    uint64_t hash;                      // of both stages: identifies the program across launches
    id<MTLFunction> fn[2];
    uint32_t gen;
} Prog;
typedef struct { uint64_t serial; int nslots; uint32_t slot[8]; int frame; } Query;

#define NAMES 65536
static Buf *bufs[NAMES];
static Tex *texs[NAMES];
static Rb *rbs[NAMES];
static Fbo *fbos[NAMES];
static Shader *shaders[NAMES];
static Prog *progs[NAMES];
static Query *queries[NAMES];
static GLuint next_name[8] = {1, 1, 1, 1, 1, 1, 1, 1};
// deleted names are reused; the free list holds every name, so none leak (a 4096-entry list used to drop
// names when the game freed thousands at once, until the pool ran out and glGenBuffers returned 0)
static GLuint free_names[8][NAMES];
static int nfree[8];
static GLuint gen_name(int pool) {
    if (nfree[pool]) return free_names[pool][--nfree[pool]];
    if (next_name[pool] < NAMES) return next_name[pool]++;
    LOG_ONCE("GL name pool %d exhausted (%d names in use)", pool, NAMES - 1);
    return 0;
}
static void free_name(int pool, GLuint n) { if (nfree[pool] < NAMES) free_names[pool][nfree[pool]++] = n; }
enum { P_BUF, P_TEX, P_RB, P_FBO, P_OBJ /* shaders and programs share a namespace */, P_QUERY };

// ---------- state ----------
typedef struct { int enabled, size, normalized, stride, divisor; GLenum type; GLuint buffer; uint64_t ptr; } Attrib;
typedef struct { GLenum func, fail, zfail, zpass; GLint ref; GLuint mask; } StencilFace;
static struct {
    GLuint prog, array_buf, elem_buf, unpack_buf, rb, draw_fbo, read_fbo;
    int unit;
    GLuint tex2d[16], texcube[16];
    float lod_bias[16];
    Attrib attr[16];
    GLint viewport[4], scissor[4];
    float depth_near, depth_far;
    int scissor_test, cull, depth_test, depth_mask, stencil_test, blend, alpha_test, poly_offset, tex2d_enabled;
    GLenum cull_face, depth_func, alpha_func;
    float alpha_ref, offset_factor, offset_units;
    StencilFace sf[2];                  // front, back
    GLuint stencil_wmask;
    GLenum bsrc_rgb, bdst_rgb, bsrc_a, bdst_a, beq_rgb, beq_a;
    int color_mask;                     // bit 0 r, 1 g, 2 b, 3 a
    float clear_color[4], clear_depth;
    GLint clear_stencil;
    int unpack_align;
    GLenum poly_mode;
    // immediate mode
    int in_begin, nimm;
    float imm[64][4], tc[2];
    GLuint active_query;
} S;

// ---------- Metal ----------
static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static CAMetalLayer *layer;
static id<MTLTexture> back_color, back_depth;   // the default framebuffer
static int back_w, back_h;
static id<MTLCommandBuffer> cmd;
static id<MTLRenderCommandEncoder> enc;
static uint64_t serial = 1;             // serial of the command buffer being recorded
static _Atomic uint64_t completed;      // highest serial whose GPU work finished
static dispatch_semaphore_t inflight;
static pthread_mutex_t L;
static void *pool;                      // autorelease pool of the frame being recorded
static pthread_t pool_thread;
#define NBUF 8                          // command buffers in flight; each has its own ring and visibility buffer
static int frame_index;                 // 0..NBUF-1, selects the ring and visibility buffers
static int queries_ended;               // occlusion queries ended in the command buffer being recorded
#define RING_SIZE (16u << 20)
static id<MTLBuffer> ring[NBUF];
static size_t ring_off;
static id<MTLBuffer> vis[NBUF];
static uint32_t vis_next;
#define VIS_SLOTS 8192
static id<MTLBuffer> zero_attr;         // (0,0,0,1) for shader inputs whose GL array is disabled
static id<MTLTexture> dummy2d, dummycube;
static id<MTLSamplerState> dummy_samp;
static dispatch_queue_t compile_q;
static MTLCompileOptions *compile_opts;  // preserveInvariance: [[invariant]] positions (multi-pass depth-equal draws)
static dispatch_semaphore_t compile_slots;

// the render pass currently open
typedef struct {
    id<MTLTexture> color[4], depth, stencil;
    int ncolor;
    int level[4], slice[4];
} Target;
static Target cur_t;
static int cur_t_valid;
static struct {                         // encoder state already set, to avoid redundant calls
    id<MTLRenderPipelineState> pipe;
    id<MTLDepthStencilState> ds;
    MTLViewport vp;
    MTLScissorRect sc;
    int cull, winding, has_vp, has_sc, stencil_ref_f, stencil_ref_b, vis_mode;
    uint32_t vis_off;
    float bias[3];
} es;

static void query_slot_for_pass(void);
// RT_METAL_PASSLOG=<frame>: describe every render pass of that frame and every read of a render
// target (texture sampling, blit source, present) to stderr, for analysing load/store needs
static int passlog_on;
static long present_count;
static void *tid_tab[4096];
static int tid_n;
static int tid(id t) {
    if (!t) return -1;
    for (int k = 0; k < tid_n; k++) if (tid_tab[k] == (void *)t) return k;
    if (tid_n < 4096) tid_tab[tid_n] = (void *)t;
    return tid_n++;
}
static int pass_draws;
#define PLOG(...) do { if (passlog_on) fprintf(stderr, "passlog: " __VA_ARGS__); } while (0)
// RT_METAL_HITCH=<ms>: log frames slower than this (default 25 when RT_FPS is set) with where the time went
static struct { double pipe, progwait, query, drawable, alloc; int npipe, nprogwait, nquery, nalloc; } hz;
static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static void lock(void) { pthread_mutex_lock(&L); }
static void unlock(void) { pthread_mutex_unlock(&L); }

static void begin_frame(void) {
    if (cmd) return;
    if (!pool) { pool = objc_autoreleasePoolPush(); pool_thread = pthread_self(); }
    dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
    cmd = [queue commandBuffer];
    [cmd retain];
    uint64_t me = serial;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) {
        (void)b;
        uint64_t c = atomic_load(&completed);
        while (me > c && !atomic_compare_exchange_weak(&completed, &c, me)) {}
        dispatch_semaphore_signal(inflight);
    }];
    ring_off = 0;
    vis_next = 0;
    memset([vis[frame_index] contents], 0, VIS_SLOTS * 8);
}

static void end_pass(void) {
    if (!enc) return;
    PLOG("  end (%d draws)\n", pass_draws);
    [enc endEncoding];
    [enc release];
    enc = nil;
    cur_t_valid = 0;
}

// commit the frame's command buffer (optionally waiting for it)
static void submit(int wait) {
    end_pass();
    if (!cmd) return;
    id<MTLCommandBuffer> c = cmd;
    cmd = nil;
    [c commit];
    if (wait) [c waitUntilCompleted];
    [c release];
    serial++;
    frame_index = (frame_index + 1) % NBUF;
    queries_ended = 0;
}

static void *ring_alloc(size_t n, id<MTLBuffer> *buf, size_t *off) {
    size_t at = (ring_off + 255) & ~(size_t)255;
    if (at + n > RING_SIZE) {                    // rare: a dedicated buffer
        id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        [b autorelease];
        *buf = b; *off = 0;
        return [b contents];
    }
    ring_off = at + n;
    *buf = ring[frame_index]; *off = at;
    return (uint8_t *)[ring[frame_index] contents] + at;
}

// ---------- formats ----------
typedef struct { GLenum ifmt; MTLPixelFormat pf; int block, bpp, compressed; } Fmt;
static const Fmt fmts[] = {
    {GL_RGBA8, MTLPixelFormatBGRA8Unorm, 1, 4, 0},
    {GL_SRGB8_ALPHA8, MTLPixelFormatBGRA8Unorm_sRGB, 1, 4, 0},
    {GL_LUMINANCE8_, MTLPixelFormatR8Unorm, 1, 1, 0},
    {GL_RG8, MTLPixelFormatRG8Unorm, 1, 2, 0},
    {GL_R32F, MTLPixelFormatR32Float, 1, 4, 0},
    {GL_RG16F, MTLPixelFormatRG16Float, 1, 4, 0},
    {GL_RGBA16F, MTLPixelFormatRGBA16Float, 1, 8, 0},
    {GL_RGBA32F, MTLPixelFormatRGBA32Float, 1, 16, 0},
    {GL_DXT1_RGB, MTLPixelFormatBC1_RGBA, 8, 0, 1},
    {GL_DXT1_RGBA, MTLPixelFormatBC1_RGBA, 8, 0, 1},
    {GL_DXT3, MTLPixelFormatBC2_RGBA, 16, 0, 1},
    {GL_DXT5, MTLPixelFormatBC3_RGBA, 16, 0, 1},
    {GL_SRGB_DXT1, MTLPixelFormatBC1_RGBA_sRGB, 8, 0, 1},
    {GL_SRGB_A_DXT1, MTLPixelFormatBC1_RGBA_sRGB, 8, 0, 1},
    {GL_SRGB_A_DXT3, MTLPixelFormatBC2_RGBA_sRGB, 16, 0, 1},
    {GL_SRGB_A_DXT5, MTLPixelFormatBC3_RGBA_sRGB, 16, 0, 1},
    {GL_DEPTH_COMPONENT24, MTLPixelFormatDepth32Float, 1, 4, 0},
    {GL_DEPTH_COMPONENT32F, MTLPixelFormatDepth32Float, 1, 4, 0},
    {GL_DEPTH24_STENCIL8, MTLPixelFormatDepth32Float_Stencil8, 1, 8, 0},
};
static const Fmt *find_fmt(GLenum ifmt) {
    for (size_t k = 0; k < sizeof fmts / sizeof *fmts; k++) if (fmts[k].ifmt == ifmt) return &fmts[k];
    return NULL;
}
static int is_depth_pf(MTLPixelFormat p) { return p == MTLPixelFormatDepth32Float || p == MTLPixelFormatDepth32Float_Stencil8; }
static int has_stencil_pf(MTLPixelFormat p) { return p == MTLPixelFormatDepth32Float_Stencil8; }

// ---------- textures ----------
static Tex *tex_of(GLuint name) { return name && name < NAMES ? texs[name] : NULL; }
static GLuint bound_tex_name(GLenum target) {
    return target == GL_TEXTURE_CUBE_MAP ? S.texcube[S.unit] : S.tex2d[S.unit];
}
static int face_of(GLenum target, GLenum *base) {
    if (target >= GL_TEXTURE_CUBE_MAP_POSITIVE_X && target <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z) {
        *base = GL_TEXTURE_CUBE_MAP; return target - GL_TEXTURE_CUBE_MAP_POSITIVE_X;
    }
    *base = target; return 0;
}

// (re)allocate storage for a texture whose level `level` is w x h
static void tex_storage(Tex *t, GLenum ifmt, int level, int w, int h) {
    int bw = w << level, bh = h << level;
    const Fmt *f = find_fmt(ifmt);
    if (!f) { LOG_ONCE("unsupported texture format 0x%x", ifmt); return; }
    if (t->mt && t->ifmt == ifmt && t->w == bw && t->h == bh) return;
    if (t->mt) [t->mt release];
    int levels = 1;
    for (int s = bw > bh ? bw : bh; s > 1; s >>= 1) levels++;
    MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
    d.textureType = t->target == GL_TEXTURE_CUBE_MAP ? MTLTextureTypeCube : MTLTextureType2D;
    d.pixelFormat = f->pf;
    d.width = bw; d.height = bh;
    d.mipmapLevelCount = levels;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead | (f->compressed || ifmt == GL_LUMINANCE8_ ? 0 : MTLTextureUsageRenderTarget);
    if (ifmt == GL_LUMINANCE8_)
        d.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne);
    t->mt = [dev newTextureWithDescriptor:d];
    [d release];
    t->ifmt = ifmt; t->pf = f->pf; t->w = bw; t->h = bh; t->levels = levels; t->maxlev_uploaded = -1;
    if (t->samp) { [t->samp release]; t->samp = nil; }
}

// BC3 alpha of block b at texel k (0..15)
static int bc3_alpha(const uint8_t *b, int k) {
    int a0 = b[0], a1 = b[1];
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits |= (uint64_t)b[2 + i] << (8 * i);
    int ix = (int)(bits >> (3 * k)) & 7;
    if (ix == 0) return a0;
    if (ix == 1) return a1;
    if (a0 > a1) return ((8 - ix) * a0 + (ix - 1) * a1) / 7;
    if (ix == 6) return 0;
    if (ix == 7) return 255;
    return ((6 - ix) * a0 + (ix - 1) * a1) / 5;
}
// Masks are white images whose shape is all in the alpha: the game's font pages and icons. Magnified
// (text at 4K/5K draws glyphs at 3-4x their size) their bilinear alpha is blurry; draws that sample one
// sharpen it (see the fragment shader rewrite in mgl_shader.cpp).
static void classify_mask(Tex *t, const uint8_t *d, int w, int h) {
    int bx = (w + 3) / 4, by = (h + 3) / 4, white = 0, coloured = 0, partial = 0;
    for (int k = 0; k < bx * by; k++) {
        const uint8_t *b = d + 16 * k;
        int amax = 0, amin = 255;
        for (int i = 0; i < 16; i++) { int a = bc3_alpha(b, i); if (a > amax) amax = a; if (a < amin) amin = a; }
        if (amax == 0) continue;                             // fully transparent: colour is irrelevant
        uint16_t c0 = b[8] | b[9] << 8, c1 = b[10] | b[11] << 8;
        int w0 = (c0 >> 11) >= 30 && ((c0 >> 5) & 63) >= 60 && (c0 & 31) >= 30;
        int w1 = (c1 >> 11) >= 30 && ((c1 >> 5) & 63) >= 60 && (c1 & 31) >= 30;
        if ((w0 && w1) || (w0 && c0 == c1)) white++; else coloured++;
        if (amin < 250) partial++;
    }
    t->mask = white > 0 && coloured * 50 <= white && partial > 0;
    if (getenv("RT_METAL_TEXSTAT"))
        MGL_LOG("texstat %dx%d white %d coloured %d partial %d -> %s\n", w, h, white, coloured, partial, t->mask ? "MASK" : "-");
    static int ndump;
    const char *dir = getenv("RT_METAL_TEXDUMP");
    if (dir && t->mask && ndump < 40) {
        char path[600]; snprintf(path, sizeof path, "%s/mask%02d_%dx%d.pgm", dir, ndump++, w, h);
        FILE *f = fopen(path, "wb");
        if (f) {
            fprintf(f, "P5 %d %d 255\n", w, h);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) fputc(bc3_alpha(d + 16 * ((y / 4) * bx + x / 4), (y % 4) * 4 + x % 4), f);
            fclose(f);
        }
    }
}

static void tex_upload(Tex *t, int level, int face, int x, int y, int w, int h, const void *data, size_t bytes,
                       GLenum format, GLenum type, int compressed) {
    if (!t->mt || !data || level >= t->levels) return;
    const Fmt *f = find_fmt(t->ifmt);
    NSUInteger row, img;
    void *conv = NULL;
    if (compressed) {
        if (level == 0 && x == 0 && y == 0 && w == t->w && h == t->h && f->block == 16 && t->target == GL_TEXTURE_2D &&
            (t->pf == MTLPixelFormatBC3_RGBA || t->pf == MTLPixelFormatBC3_RGBA_sRGB))
            classify_mask(t, data, w, h);
        int bx = (w + 3) / 4, by = (h + 3) / 4;
        row = bx * f->block; img = row * by;
        (void)bytes;
    } else {
        int bpp = f->bpp;
        if (t->ifmt == GL_RGBA8 || t->ifmt == GL_SRGB8_ALPHA8) {
            if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {   // swap to BGRA
                conv = malloc((size_t)w * h * 4);
                size_t sr = ((size_t)w * 4 + S.unpack_align - 1) / S.unpack_align * S.unpack_align;
                for (int r = 0; r < h; r++) {
                    const uint8_t *s = (const uint8_t *)data + r * sr;
                    uint8_t *d = (uint8_t *)conv + (size_t)r * w * 4;
                    for (int c = 0; c < w; c++) { d[4*c] = s[4*c+2]; d[4*c+1] = s[4*c+1]; d[4*c+2] = s[4*c]; d[4*c+3] = s[4*c+3]; }
                }
                data = conv;
                row = (NSUInteger)w * 4;
            } else if (format != GL_BGRA) { LOG_ONCE("RGBA8 upload from format 0x%x type 0x%x", format, type); }
        }
        if (!conv) row = ((NSUInteger)w * bpp + S.unpack_align - 1) / S.unpack_align * S.unpack_align;
        img = row * h;
    }
    [t->mt replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:level slice:face withBytes:data bytesPerRow:row bytesPerImage:img];
    if (level > t->maxlev_uploaded) t->maxlev_uploaded = level;
    if (t->samp) { [t->samp release]; t->samp = nil; }
    free(conv);
}

static const void *unpack_ptr(uint64_t p) {
    if (S.unpack_buf && bufs[S.unpack_buf] && bufs[S.unpack_buf]->mb) return (uint8_t *)[bufs[S.unpack_buf]->mb contents] + p;
    return (const void *)p;
}

static MTLSamplerAddressMode wrap_mode(GLint w) {
    switch (w) {
        case GL_REPEAT: return MTLSamplerAddressModeRepeat;
        case GL_MIRRORED_REPEAT: return MTLSamplerAddressModeMirrorRepeat;
        default: return MTLSamplerAddressModeClampToEdge;
    }
}
static id<MTLSamplerState> sampler_for(Tex *t) {
    if (t->samp) return t->samp;
    MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
    GLint mn = t->min_f;
    d.minFilter = (mn == GL_NEAREST || mn == GL_NEAREST_MIPMAP_NEAREST || mn == GL_NEAREST_MIPMAP_LINEAR) ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    d.magFilter = t->mag_f == GL_NEAREST ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    d.mipFilter = (mn == GL_NEAREST || mn == GL_LINEAR) ? MTLSamplerMipFilterNotMipmapped :
                  (mn == GL_NEAREST_MIPMAP_NEAREST || mn == GL_LINEAR_MIPMAP_NEAREST) ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    d.sAddressMode = wrap_mode(t->wrap_s);
    d.tAddressMode = wrap_mode(t->wrap_t);
    d.rAddressMode = wrap_mode(t->wrap_t);
    int maxa = (int)t->aniso;
    d.maxAnisotropy = maxa < 1 ? 1 : maxa > 16 ? 16 : maxa;
    float top = t->maxlev_uploaded < 0 ? 0 : t->maxlev_uploaded;
    if (t->max_level < top) top = t->max_level;
    d.lodMinClamp = t->base_level;
    d.lodMaxClamp = top;
    t->samp = [dev newSamplerStateWithDescriptor:d];
    [d release];
    return t->samp;
}

// ---------- buffers ----------
static Buf *buf_bound(GLenum target) {
    GLuint n = target == GL_ARRAY_BUFFER ? S.array_buf : target == GL_ELEMENT_ARRAY_BUFFER ? S.elem_buf :
               target == GL_PIXEL_UNPACK_BUFFER ? S.unpack_buf : 0;
    return n && n < NAMES ? bufs[n] : NULL;
}
static void buf_alloc(Buf *b, size_t size, const void *data, int keep) {
    double t0 = now_ms();
    id<MTLBuffer> nb = [dev newBufferWithLength:(size ? size : 16) options:MTLResourceStorageModeShared];
    hz.alloc += now_ms() - t0; hz.nalloc++;
    if (data) memcpy([nb contents], data, size);
    else if (keep && b->mb) memcpy([nb contents], [b->mb contents], size < b->size ? size : b->size);
    if (b->mb) [b->mb release];
    b->mb = nb; b->size = size; b->used = 0;
}

// ---------- framebuffers ----------
static id<MTLTexture> att_texture(const Att *a, int *level, int *slice) {
    *level = 0; *slice = 0;
    if (a->kind == 1) { Tex *t = tex_of(a->name); *level = a->level; *slice = a->face; return t ? t->mt : nil; }
    if (a->kind == 2) { Rb *r = a->name < NAMES ? rbs[a->name] : NULL; return r ? r->mt : nil; }
    return nil;
}

static double render_scale(void);
static void ensure_backbuffer(void) {
    if (!layer) return;
    CGSize sz = layer.drawableSize;
    double rs = render_scale();
    if (rs > 0) { sz = layer.bounds.size; sz.width = round(sz.width * rs); sz.height = round(sz.height * rs); }
    int w = (int)sz.width, h = (int)sz.height;
    if (w <= 0 || h <= 0) return;
    if (back_color && back_w == w && back_h == h) return;
    if (back_color) { [back_color release]; [back_depth release]; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    back_color = [dev newTextureWithDescriptor:d];
    d.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    back_depth = [dev newTextureWithDescriptor:d];
    back_w = w; back_h = h;
}

// the render target described by the current draw framebuffer
static void current_target(Target *t) {
    memset(t, 0, sizeof *t);
    if (!S.draw_fbo) {
        ensure_backbuffer();
        t->color[0] = back_color; t->ncolor = back_color ? 1 : 0;
        t->depth = back_depth; t->stencil = back_depth;
        return;
    }
    Fbo *f = fbos[S.draw_fbo];
    if (!f) return;
    int lv, sl;
    if (!f->draw_none)
        for (int k = 0; k < 4; k++) {
            t->color[k] = att_texture(&f->color[k], &t->level[k], &t->slice[k]);
            if (t->color[k]) t->ncolor = k + 1;
        }
    t->depth = att_texture(&f->depth, &lv, &sl);
    t->stencil = att_texture(&f->stencil, &lv, &sl);
    if (!t->depth && t->stencil && is_depth_pf(t->stencil.pixelFormat)) t->depth = t->stencil;
    if (t->depth && !t->stencil && has_stencil_pf(t->depth.pixelFormat)) t->stencil = t->depth;
}

static int same_target(const Target *a, const Target *b) { return !memcmp(a, b, sizeof *a); }

// ---------- deferred clears (RT_METAL_DEFER=1; measured no GPU gain on the first level) ----------
// A full clear is not executed when issued: it is recorded per attachment texture and becomes the
// clear load action of the next render pass that uses the texture, so a clear never costs a pass of
// its own. Anything that reads the texture first (sampling, blit source, present) executes it.
typedef struct { id<MTLTexture> tex; int level, slice, kind; float color[4]; float depth; uint32_t stencil; } PendingClear;
enum { PC_COLOR, PC_DEPTH, PC_STENCIL };
#define MAX_PC 64
static PendingClear pcs[MAX_PC];
static int npcs;
static int pc_find(id<MTLTexture> t, int level, int slice, int kind) {
    for (int k = 0; k < npcs; k++) if (pcs[k].tex == t && pcs[k].level == level && pcs[k].slice == slice && pcs[k].kind == kind) return k;
    return -1;
}
static void pc_remove(int k) { [pcs[k].tex release]; pcs[k] = pcs[--npcs]; }
static void pc_add(id<MTLTexture> t, int level, int slice, int kind) {
    if (!t) return;
    int k = pc_find(t, level, slice, kind);
    if (k < 0) {
        if (npcs == MAX_PC) { LOG_ONCE("too many deferred clears"); return; }
        k = npcs++;
        pcs[k].tex = [t retain]; pcs[k].level = level; pcs[k].slice = slice; pcs[k].kind = kind;
    }
    memcpy(pcs[k].color, S.clear_color, sizeof pcs[k].color);
    pcs[k].depth = S.clear_depth;
    pcs[k].stencil = S.clear_stencil;
}
static void end_pass(void);
static void begin_frame(void);
// execute the deferred clears of a texture now (it is about to be read)
static void pc_flush(id<MTLTexture> t) {
    if (!npcs || !t) return;
    for (int k = 0; k < npcs; ) {
        if (pcs[k].tex != t) { k++; continue; }
        begin_frame();
        end_pass();
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        if (pcs[k].kind == PC_COLOR) {
            rp.colorAttachments[0].texture = t; rp.colorAttachments[0].level = pcs[k].level; rp.colorAttachments[0].slice = pcs[k].slice;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(pcs[k].color[0], pcs[k].color[1], pcs[k].color[2], pcs[k].color[3]);
        } else if (pcs[k].kind == PC_DEPTH) {
            rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = pcs[k].depth;
        } else {
            rp.stencilAttachment.texture = t; rp.stencilAttachment.loadAction = MTLLoadActionClear;
            rp.stencilAttachment.storeAction = MTLStoreActionStore; rp.stencilAttachment.clearStencil = pcs[k].stencil;
        }
        [[cmd renderCommandEncoderWithDescriptor:rp] endEncoding];
        pc_remove(k);
    }
}

// load action for an attachment: its deferred clear, DontCare when the caller overwrites it all, else Load
static MTLLoadAction pass_load(id<MTLTexture> t, int level, int slice, int kind, int clear_now, int dontcare, MTLRenderPassAttachmentDescriptor *a) {
    int k = pc_find(t, level, slice, kind);
    if (clear_now || dontcare) { if (k >= 0) pc_remove(k); }
    if (clear_now) return MTLLoadActionClear;
    if (dontcare) return MTLLoadActionDontCare;
    if (k < 0) return MTLLoadActionLoad;
    if (kind == PC_COLOR) ((MTLRenderPassColorAttachmentDescriptor *)a).clearColor = MTLClearColorMake(pcs[k].color[0], pcs[k].color[1], pcs[k].color[2], pcs[k].color[3]);
    else if (kind == PC_DEPTH) ((MTLRenderPassDepthAttachmentDescriptor *)a).clearDepth = pcs[k].depth;
    else ((MTLRenderPassStencilAttachmentDescriptor *)a).clearStencil = pcs[k].stencil;
    pc_remove(k);
    return MTLLoadActionClear;
}

static void ensure_pass_ex(GLbitfield clear_mask, int color_dontcare);
// open (or keep) a render pass on the current framebuffer; clear_mask uses GL bits
static void ensure_pass(GLbitfield clear_mask) { ensure_pass_ex(clear_mask, 0); }
static void ensure_pass_ex(GLbitfield clear_mask, int color_dontcare) {
    begin_frame();
    Target t;
    current_target(&t);
    if (enc && cur_t_valid && same_target(&t, &cur_t) && !clear_mask) return;
    end_pass();
    if (queries_ended && !S.active_query) {     // let the GPU start on them (the game waits for these results)
        submit(0);
        begin_frame();
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int k = 0; k < t.ncolor; k++) {
        if (!t.color[k]) continue;
        rp.colorAttachments[k].texture = t.color[k];
        rp.colorAttachments[k].level = t.level[k];
        rp.colorAttachments[k].slice = t.slice[k];
        rp.colorAttachments[k].storeAction = MTLStoreActionStore;
        rp.colorAttachments[k].clearColor = MTLClearColorMake(S.clear_color[0], S.clear_color[1], S.clear_color[2], S.clear_color[3]);
        rp.colorAttachments[k].loadAction = pass_load(t.color[k], t.level[k], t.slice[k], PC_COLOR, (clear_mask & GL_COLOR_BUFFER_BIT) != 0,
                                                      color_dontcare, rp.colorAttachments[k]);
    }
    if (t.depth) {
        rp.depthAttachment.texture = t.depth;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        rp.depthAttachment.clearDepth = S.clear_depth;
        rp.depthAttachment.loadAction = pass_load(t.depth, 0, 0, PC_DEPTH, (clear_mask & GL_DEPTH_BUFFER_BIT) != 0, 0, rp.depthAttachment);
    }
    if (t.stencil) {
        rp.stencilAttachment.texture = t.stencil;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
        rp.stencilAttachment.clearStencil = S.clear_stencil;
        rp.stencilAttachment.loadAction = pass_load(t.stencil, 0, 0, PC_STENCIL, (clear_mask & GL_STENCIL_BUFFER_BIT) != 0, 0, rp.stencilAttachment);
    }
    if (!t.ncolor && !t.depth && !t.stencil) { LOG_ONCE("draw with no attachments (fbo %u)", S.draw_fbo); return; }
    rp.visibilityResultBuffer = vis[frame_index];
    if (passlog_on) {
        pass_draws = 0;
        char b[512];
        int n = snprintf(b, sizeof b, "pass fbo %u:", S.draw_fbo);
        for (int k = 0; k < t.ncolor; k++) if (t.color[k])
            n += snprintf(b + n, sizeof b - n, " c%d=t%d(%lux%lu f%lu %s)", k, tid(t.color[k]), (unsigned long)t.color[k].width,
                          (unsigned long)t.color[k].height, (unsigned long)t.color[k].pixelFormat, (clear_mask & GL_COLOR_BUFFER_BIT) ? "clear" : "load");
        if (t.depth) n += snprintf(b + n, sizeof b - n, " d=t%d(%lux%lu %s)", tid(t.depth), (unsigned long)t.depth.width, (unsigned long)t.depth.height, (clear_mask & GL_DEPTH_BUFFER_BIT) ? "clear" : "load");
        if (t.stencil) n += snprintf(b + n, sizeof b - n, " s=t%d(%s)", tid(t.stencil), (clear_mask & GL_STENCIL_BUFFER_BIT) ? "clear" : "load");
        PLOG("%s\n", b);
    }
    enc = [[cmd renderCommandEncoderWithDescriptor:rp] retain];
    cur_t = t;
    cur_t_valid = 1;
    memset(&es, 0, sizeof es);
    es.vis_mode = -1;
    es.cull = -1; es.winding = -1;
    es.stencil_ref_f = es.stencil_ref_b = -1;
    query_slot_for_pass();
}

// ---------- pipelines ----------
typedef struct {
    uint64_t vsh, fsh;                  // game programs: the hashes of their two compiled stages
    uint8_t vfmt[16], vstep[16];        // per attribute location: format (0 = unused), step
    uint16_t vstride[16];
    uint32_t vdiv[16];
    uint16_t cfmt[4], dfmt, sfmt;
    uint8_t blend, wmask;
    uint16_t bsrc_rgb, bdst_rgb, bsrc_a, bdst_a, beq_rgb, beq_a;
    uint8_t kind;                       // 0 game program, 1 blit, 2 immediate, 3 present
} PipeKey;
#define PIPE_CACHE 8192
static struct { PipeKey k; id<MTLRenderPipelineState> p; int used; } pipes[PIPE_CACHE];

static MTLBlendFactor bfac(GLenum f) {
    switch (f) {
        case GL_ZERO: return MTLBlendFactorZero;
        case GL_ONE: return MTLBlendFactorOne;
        case GL_SRC_COLOR: return MTLBlendFactorSourceColor;
        case GL_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
        case GL_SRC_ALPHA: return MTLBlendFactorSourceAlpha;
        case GL_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
        case GL_DST_ALPHA: return MTLBlendFactorDestinationAlpha;
        case GL_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
        case GL_DST_COLOR: return MTLBlendFactorDestinationColor;
        case GL_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
        case GL_SRC_ALPHA_SATURATE: return MTLBlendFactorSourceAlphaSaturated;
        default: LOG_ONCE("blend factor 0x%x", f); return MTLBlendFactorOne;
    }
}
static MTLBlendOperation bop(GLenum e) {
    switch (e) {
        case GL_FUNC_SUBTRACT: return MTLBlendOperationSubtract;
        case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
        case GL_MIN: return MTLBlendOperationMin;
        case GL_MAX: return MTLBlendOperationMax;
        default: return MTLBlendOperationAdd;
    }
}

static uint32_t hash_bytes(const void *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t k = 0; k < n; k++) h = (h ^ ((const uint8_t *)p)[k]) * 16777619u;
    return h;
}

static id<MTLFunction> internal_fn[8];  // see init_internal
static void pipe_record(const PipeKey *k);
static id<MTLRenderPipelineState> pipe_find(const PipeKey *k) {
    uint32_t h = hash_bytes(k, sizeof *k) % PIPE_CACHE;
    for (int probe = 0; probe < PIPE_CACHE; probe++, h = (h + 1) % PIPE_CACHE) {
        if (!pipes[h].used) return nil;
        if (!memcmp(&pipes[h].k, k, sizeof *k)) return pipes[h].p;
    }
    return nil;
}
static void pipe_insert(const PipeKey *k, id<MTLRenderPipelineState> p) {
    uint32_t h = hash_bytes(k, sizeof *k) % PIPE_CACHE;
    for (int probe = 0; probe < PIPE_CACHE; probe++, h = (h + 1) % PIPE_CACHE)
        if (!pipes[h].used || !memcmp(&pipes[h].k, k, sizeof *k)) break;
    if (pipes[h].used) { if (memcmp(&pipes[h].k, k, sizeof *k)) LOG_ONCE("pipeline cache full"); [pipes[h].p release]; }
    pipes[h].k = *k; pipes[h].p = p; pipes[h].used = 1;
}
static id<MTLRenderPipelineState> make_pipeline(const PipeKey *k, id<MTLFunction> vf, id<MTLFunction> ff);
static id<MTLRenderPipelineState> pipeline(const PipeKey *k, id<MTLFunction> vf, id<MTLFunction> ff) {
    id<MTLRenderPipelineState> p = pipe_find(k);
    if (p) return p;
    double t0 = now_ms();
    p = make_pipeline(k, vf, ff);
    hz.pipe += now_ms() - t0; hz.npipe++;
    if (!p) return nil;
    pipe_insert(k, p);
    if (k->kind == 0) pipe_record(k);
    return p;
}
// builds a pipeline state (thread-safe; no shared state)
static id<MTLRenderPipelineState> make_pipeline(const PipeKey *k, id<MTLFunction> vf, id<MTLFunction> ff) {
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = vf;
    d.fragmentFunction = ff;
    if (k->kind == 0) {
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        for (int l = 0; l < 16; l++) {
            if (!k->vfmt[l]) continue;
            vd.attributes[l].format = (MTLVertexFormat)k->vfmt[l];
            vd.attributes[l].offset = 0;
            vd.attributes[l].bufferIndex = 1 + l;
            vd.layouts[1 + l].stride = k->vstride[l] ? k->vstride[l] : 16;
            vd.layouts[1 + l].stepFunction = (MTLVertexStepFunction)k->vstep[l];
            vd.layouts[1 + l].stepRate = k->vstep[l] == MTLVertexStepFunctionConstant ? 0 : (k->vdiv[l] ? k->vdiv[l] : 1);
        }
        d.vertexDescriptor = vd;
    }
    for (int c = 0; c < 4; c++) {
        if (!k->cfmt[c]) continue;
        MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[c];
        ca.pixelFormat = (MTLPixelFormat)k->cfmt[c];
        ca.writeMask = ((k->wmask & 1) ? MTLColorWriteMaskRed : 0) | ((k->wmask & 2) ? MTLColorWriteMaskGreen : 0) |
                       ((k->wmask & 4) ? MTLColorWriteMaskBlue : 0) | ((k->wmask & 8) ? MTLColorWriteMaskAlpha : 0);
        if (k->blend) {
            ca.blendingEnabled = YES;
            ca.sourceRGBBlendFactor = bfac(k->bsrc_rgb); ca.destinationRGBBlendFactor = bfac(k->bdst_rgb);
            ca.sourceAlphaBlendFactor = bfac(k->bsrc_a); ca.destinationAlphaBlendFactor = bfac(k->bdst_a);
            ca.rgbBlendOperation = bop(k->beq_rgb); ca.alphaBlendOperation = bop(k->beq_a);
        }
    }
    d.depthAttachmentPixelFormat = (MTLPixelFormat)k->dfmt;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)k->sfmt;
    NSError *err = nil;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    [d release];
    if (!p) LOG_ONCE("pipeline failed (stages %016llx/%016llx kind %d): %s", (unsigned long long)k->vsh, (unsigned long long)k->fsh, k->kind, err.localizedDescription.UTF8String);
    return p;
}

typedef struct {
    uint8_t depth_test, depth_write, stencil;
    uint16_t depth_func;
    StencilFace f[2];
    GLuint wmask;
} DsKey;
#define DS_CACHE 512
static struct { DsKey k; id<MTLDepthStencilState> s; int used; } dss[DS_CACHE];
static MTLCompareFunction cmpf(GLenum f) {
    switch (f) {
        case GL_NEVER: return MTLCompareFunctionNever;
        case GL_LESS: return MTLCompareFunctionLess;
        case GL_EQUAL: return MTLCompareFunctionEqual;
        case GL_LEQUAL: return MTLCompareFunctionLessEqual;
        case GL_GREATER: return MTLCompareFunctionGreater;
        case GL_NOTEQUAL: return MTLCompareFunctionNotEqual;
        case GL_GEQUAL: return MTLCompareFunctionGreaterEqual;
        default: return MTLCompareFunctionAlways;
    }
}
static MTLStencilOperation sop(GLenum o) {
    switch (o) {
        case GL_ZERO: return MTLStencilOperationZero;
        case GL_REPLACE: return MTLStencilOperationReplace;
        case GL_INCR: return MTLStencilOperationIncrementClamp;
        case GL_DECR: return MTLStencilOperationDecrementClamp;
        case GL_INVERT: return MTLStencilOperationInvert;
        case GL_INCR_WRAP: return MTLStencilOperationIncrementWrap;
        case GL_DECR_WRAP: return MTLStencilOperationDecrementWrap;
        default: return MTLStencilOperationKeep;
    }
}
static id<MTLDepthStencilState> ds_lookup(DsKey k);
static id<MTLDepthStencilState> ds_state(int has_depth, int has_stencil) {
    DsKey k;
    memset(&k, 0, sizeof k);
    k.depth_test = has_depth && S.depth_test;
    k.depth_write = has_depth && S.depth_test && S.depth_mask;
    k.depth_func = k.depth_test ? S.depth_func : GL_ALWAYS;
    k.stencil = has_stencil && S.stencil_test;
    if (k.stencil) {
        k.f[0] = S.sf[0]; k.f[1] = S.sf[1]; k.wmask = S.stencil_wmask;
        k.f[0].ref = k.f[1].ref = 0;    // reference values are dynamic state
    }
    return ds_lookup(k);
}
static id<MTLDepthStencilState> ds_lookup(DsKey k) {
    uint32_t h = hash_bytes(&k, sizeof k) % DS_CACHE;
    for (int probe = 0; probe < DS_CACHE; probe++, h = (h + 1) % DS_CACHE) {
        if (!dss[h].used) break;
        if (!memcmp(&dss[h].k, &k, sizeof k)) return dss[h].s;
    }
    MTLDepthStencilDescriptor *d = [[MTLDepthStencilDescriptor alloc] init];
    d.depthCompareFunction = cmpf(k.depth_func);
    d.depthWriteEnabled = k.depth_write;
    if (k.stencil) {
        for (int f = 0; f < 2; f++) {
            MTLStencilDescriptor *s = [[MTLStencilDescriptor alloc] init];
            s.stencilCompareFunction = cmpf(k.f[f].func);
            s.stencilFailureOperation = sop(k.f[f].fail);
            s.depthFailureOperation = sop(k.f[f].zfail);
            s.depthStencilPassOperation = sop(k.f[f].zpass);
            s.readMask = k.f[f].mask;
            s.writeMask = k.wmask;
            if (f == 0) d.frontFaceStencil = s; else d.backFaceStencil = s;
            [s release];
        }
    }
    id<MTLDepthStencilState> s = [dev newDepthStencilStateWithDescriptor:d];
    [d release];
    if (dss[h].used) [dss[h].s release];
    dss[h].k = k; dss[h].s = s; dss[h].used = 1;
    return s;
}

// ---------- internal shaders (blit, immediate mode, present) ----------
static const char *internal_msl =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 pos [[position]]; float2 uv; };\n"
    "vertex V quad_vs(uint vid [[vertex_id]], constant float4 *v [[buffer(0)]]) {\n"
    "    V o; o.pos = float4(v[vid].xy, 0.0, 1.0); o.uv = v[vid].zw; return o; }\n"
    "fragment float4 copy_fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "    return t.sample(s, in.uv); }\n"
    "fragment float4 imm_fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],\n"
    "                       constant float4 &p [[buffer(0)]]) {\n"
    "    float4 c = p.y > 0.5 ? t.sample(s, in.uv) : float4(1.0);\n"
    "    if (p.z > 0.5 && !(c.a > p.x)) discard_fragment();\n"
    "    return c; }\n"
    "struct ClearOut { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; float4 c3 [[color(3)]];\n"
    "                  float d [[depth(any)]]; };\n"
    "fragment ClearOut clear_fs(V in [[stage_in]], constant float4 *p [[buffer(0)]]) {\n"
    "    ClearOut o; o.c0 = o.c1 = o.c2 = o.c3 = p[0]; o.d = p[1].x; return o; }\n"
    "struct ClearOutC { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; float4 c3 [[color(3)]]; };\n"
    "fragment ClearOutC clear_color_fs(V in [[stage_in]], constant float4 *p [[buffer(0)]]) {\n"
    "    ClearOutC o; o.c0 = o.c1 = o.c2 = o.c3 = p[0]; return o; }\n";
enum { FN_QUAD_VS, FN_COPY_FS, FN_IMM_FS, FN_CLEAR_FS, FN_CLEAR_COLOR_FS };
static id<MTLSamplerState> samp_linear, samp_nearest;

static void init_internal(void) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:internal_msl] options:nil error:&err];
    if (!lib) { MGL_LOG("internal shaders failed: %s\n", err.localizedDescription.UTF8String); abort(); }
    internal_fn[FN_QUAD_VS] = [lib newFunctionWithName:@"quad_vs"];
    internal_fn[FN_COPY_FS] = [lib newFunctionWithName:@"copy_fs"];
    internal_fn[FN_IMM_FS] = [lib newFunctionWithName:@"imm_fs"];
    internal_fn[FN_CLEAR_FS] = [lib newFunctionWithName:@"clear_fs"];
    internal_fn[FN_CLEAR_COLOR_FS] = [lib newFunctionWithName:@"clear_color_fs"];
    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    samp_linear = [dev newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    samp_nearest = [dev newSamplerStateWithDescriptor:sd];
    [sd release];
}

// draw a textured quad: corners in Metal NDC (x right, y up from the bottom of memory... see callers)
static void internal_quad(int kind, id<MTLFunction> ff, id<MTLTexture> src, id<MTLSamplerState> smp,
                          const float v[4][4], const float *fparams) {
    PipeKey k;
    memset(&k, 0, sizeof k);
    k.kind = kind;
    for (int c = 0; c < cur_t.ncolor; c++) if (cur_t.color[c]) k.cfmt[c] = cur_t.color[c].pixelFormat;
    k.dfmt = cur_t.depth ? cur_t.depth.pixelFormat : 0;
    k.sfmt = cur_t.stencil ? cur_t.stencil.pixelFormat : 0;
    k.wmask = 15;
    if (kind == 2 && S.blend) {
        k.blend = 1; k.bsrc_rgb = S.bsrc_rgb; k.bdst_rgb = S.bdst_rgb; k.bsrc_a = S.bsrc_a; k.bdst_a = S.bdst_a;
        k.beq_rgb = S.beq_rgb; k.beq_a = S.beq_a;
    }
    id<MTLRenderPipelineState> p = pipeline(&k, internal_fn[FN_QUAD_VS], ff);
    if (!p) return;
    [enc setRenderPipelineState:p];
    es.pipe = p;
    [enc setDepthStencilState:ds_state(0, 0)];
    es.ds = nil;
    [enc setCullMode:MTLCullModeNone];
    es.cull = -1;
    [enc setVertexBytes:v length:sizeof(float) * 16 atIndex:0];
    [enc setFragmentTexture:src atIndex:0];
    [enc setFragmentSamplerState:smp atIndex:0];
    if (fparams) [enc setFragmentBytes:fparams length:16 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// ---------- programs ----------
// ---------- persistent pipeline list ----------
// Every pipeline built for a game draw is appended to a file. Pipelines are keyed by the hashes of
// their two shader stages (not GL program names), so at startup every recorded pipeline whose stages
// are in the precompiled shader cache is built in the background before the game needs it.
static PipeKey *recs;
static size_t nrecs;
static FILE *rec_file;
static int rec_cmp(const void *a, const void *b) { return memcmp(a, b, sizeof(PipeKey)); }
static void pipe_records_load(void) {
    char dir[512], path[600];
    snprintf(dir, sizeof dir, "%s/Library/Caches/ShadowComplexRecomp", getenv("HOME"));
    mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/pipelines-v4.bin", dir);
    FILE *f = fopen(path, "rb");
    size_t cap = 0;
    if (f) {
        PipeKey k;
        while (fread(&k, sizeof k, 1, f) == 1) {
            if (nrecs == cap) { cap = cap ? cap * 2 : 1024; recs = realloc(recs, cap * sizeof *recs); }
            recs[nrecs++] = k;
        }
        fclose(f);
        qsort(recs, nrecs, sizeof *recs, rec_cmp);
        size_t w = 0;
        for (size_t k = 0; k < nrecs; k++) if (!w || memcmp(&recs[k], &recs[w - 1], sizeof *recs)) recs[w++] = recs[k];
        nrecs = w;
    }
    rec_file = fopen(path, "ab");
}
static void pipe_record(const PipeKey *k) {
    if (!rec_file || bsearch(k, recs, nrecs, sizeof *recs, rec_cmp)) return;
    fwrite(k, sizeof *k, 1, rec_file);
    fflush(rec_file);
}
static id<MTLFunction> lib_cache_load(uint64_t hash);
// build every recorded pipeline whose stages are precompiled (background, at startup)
static void pipe_prewarm(void) {
    if (!nrecs) return;
    MGL_LOG("building %zu recorded pipelines in the background\n", nrecs);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double t0 = now_ms();
        __block _Atomic int built = 0;
        dispatch_apply(nrecs, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            const PipeKey *k = &recs[i];
            lock();
            int have = pipe_find(k) != nil;
            id<MTLFunction> v = have ? nil : lib_cache_load(k->vsh), f = have ? nil : lib_cache_load(k->fsh);
            unlock();
            if (v && f) {
                id<MTLRenderPipelineState> ps = make_pipeline(k, v, f);
                lock();
                if (ps && !pipe_find(k)) { pipe_insert(k, ps); built++; } else [ps release];
                unlock();
            }
            [v release]; [f release];
        });
        MGL_LOG("built %d recorded pipelines in %.0f ms\n", (int)built, now_ms() - t0);
    });
}

// ---------- shader compilation ----------
// Each shader stage is compiled once, keyed by a hash of its source (plus attribute locations for
// vertex shaders), as soon as the game hands it over: the engine compiles all ~10,000 shaders at
// startup but links programs only right before first use. Stages are compiled in batches of 64
// (each in its own namespace): <metal_stdlib> dominates a single compile, so a batch costs ~8 ms
// per shader instead of ~110 ms. Compiled batches are written to disk and turned into .metallib
// files in the background (xcrun metal); later launches load functions from those directly.
// Vertex shaders are precompiled with attribute locations predicted from a saved name -> location
// map (UE3 binds attributes by name consistently); a draw that needs a stage before its batch has
// run compiles that stage on its own.
typedef struct SJob {
    _Atomic int claimed, done;
    int stage;
    char *src;
    MglAttrib attrs[16];
    int nattrs;
    uint64_t hash;
    dispatch_group_t group;             // left once fn is set
    id<MTLFunction> fn;                 // nil if the stage failed
} SJob;
#define SJ_CAP 65536
static SJob *sjobs[SJ_CAP];

static uint64_t fnv64(uint64_t h, const void *data, size_t n) {
    for (size_t k = 0; k < n; k++) h = (h ^ ((const uint8_t *)data)[k]) * 1099511628211ull;
    return h;
}
static SJob *sj_find(uint64_t h) {
    for (uint64_t i = h % SJ_CAP, probe = 0; probe < SJ_CAP; probe++, i = (i + 1) % SJ_CAP) {
        if (!sjobs[i]) return NULL;
        if (sjobs[i]->hash == h) return sjobs[i];
    }
    return NULL;
}
static void sj_insert(SJob *j) {
    for (uint64_t i = j->hash % SJ_CAP, probe = 0; probe < SJ_CAP; probe++, i = (i + 1) % SJ_CAP)
        if (!sjobs[i]) { sjobs[i] = j; return; }
    LOG_ONCE("shader table full");
}
static void sj_finish(SJob *j, id<MTLFunction> fn) {
    j->fn = fn;
    atomic_store(&j->done, 1);
    dispatch_group_leave(j->group);
}
static char *sj_msl(SJob *j) {
    char err[1024];
    char *msl = mgl_to_msl(j->src, j->stage, j->attrs, j->nattrs, NULL, err, sizeof err);
    if (!msl) MGL_LOG("shader %016llx (stage %d) conversion failed: %s\n", (unsigned long long)j->hash, j->stage, err);
    return msl;
}
// compile one claimed stage on its own
static void sj_compile_single(SJob *j) {
    id<MTLFunction> fn = nil;
    char *msl = sj_msl(j);
    if (msl) {
        NSError *ne = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:compile_opts error:&ne];
        if (lib) { fn = [lib newFunctionWithName:@"main0"]; [lib release]; }
        else MGL_LOG("shader %016llx Metal compile failed: %s\n", (unsigned long long)j->hash, ne.localizedDescription.UTF8String);
        free(msl);
    }
    sj_finish(j, fn);
}

// ---- precompiled cache on disk ----
typedef struct { uint64_t stage, batch; int k; } LibIdx;
static LibIdx *libidx;
static size_t nlibidx;
static FILE *libidx_file;
static char libdir[512];
static NSMutableDictionary *loaded_libs;        // batch id -> id<MTLLibrary>
static dispatch_queue_t metallib_q;
static dispatch_semaphore_t metallib_slots;     // concurrent xcrun builds
static int libidx_cmp(const void *a, const void *b) {
    uint64_t x = ((const LibIdx *)a)->stage, y = ((const LibIdx *)b)->stage;
    return x < y ? -1 : x > y;
}
// saved attribute name -> location map (for predicting vertex shader attribute locations)
static struct { char name[64]; int loc; } amap[128];
static int namap;
static FILE *amap_file;
static int amap_get(const char *name) {
    for (int k = 0; k < namap; k++) if (!strcmp(amap[k].name, name)) return amap[k].loc;
    return -1;
}
static void amap_set(const char *name, int loc) {
    for (int k = 0; k < namap; k++)
        if (!strcmp(amap[k].name, name)) { if (amap[k].loc == loc) return; amap[k].loc = loc; goto save; }
    if (namap == 128) return;
    snprintf(amap[namap].name, 64, "%s", name);
    amap[namap++].loc = loc;
save:
    if (amap_file) { fprintf(amap_file, "%s %d\n", name, loc); fflush(amap_file); }
}

static void lib_cache_init(void) {
    char parent[512], path[600];
    snprintf(parent, sizeof parent, "%s/Library/Caches/ShadowComplexRecomp", getenv("HOME"));
    mkdir(parent, 0755);
    snprintf(libdir, sizeof libdir, "%s/lib-v3", parent);
    mkdir(libdir, 0755);
    snprintf(path, sizeof path, "%s/index.txt", libdir);
    FILE *f = fopen(path, "r");
    size_t cap = 0;
    if (f) {
        unsigned long long a, b;
        int k;
        while (fscanf(f, "%llx %llx %d", &a, &b, &k) == 3) {
            if (nlibidx == cap) { cap = cap ? cap * 2 : 4096; libidx = realloc(libidx, cap * sizeof *libidx); }
            libidx[nlibidx++] = (LibIdx){a, b, k};
        }
        fclose(f);
        qsort(libidx, nlibidx, sizeof *libidx, libidx_cmp);
    }
    libidx_file = fopen(path, "a");
    snprintf(path, sizeof path, "%s/attribs.txt", libdir);
    f = fopen(path, "r");
    if (f) {
        char name[64];
        int loc;
        while (fscanf(f, "%63s %d", name, &loc) == 2) {
            int k;
            for (k = 0; k < namap; k++) if (!strcmp(amap[k].name, name)) break;
            if (k == namap && namap < 128) namap++;
            if (k < 128) { snprintf(amap[k].name, 64, "%s", name); amap[k].loc = loc; }
        }
        fclose(f);
    }
    amap_file = fopen(path, "a");
    loaded_libs = [[NSMutableDictionary alloc] init];
    metallib_q = dispatch_queue_create("mgl.metallib", DISPATCH_QUEUE_CONCURRENT);
    dispatch_set_target_queue(metallib_q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    metallib_slots = dispatch_semaphore_create(4);
    if (nlibidx) MGL_LOG("%zu shaders in the precompiled cache\n", nlibidx);
}

// a cached stage's function, or nil (lock held)
// RT_METAL_NO_METALLIB=1: behave as on a Mac without Xcode's Metal toolchain (no .metallib cache)
static int no_metallib(void) {
    static int v = -1;
    if (v < 0) v = getenv("RT_METAL_NO_METALLIB") != 0;
    return v;
}
static id<MTLFunction> lib_cache_load(uint64_t hash) {
    if (no_metallib()) return nil;
    LibIdx key = {hash};
    LibIdx *e = bsearch(&key, libidx, nlibidx, sizeof *libidx, libidx_cmp);
    if (!e) return nil;
    NSNumber *bid = [NSNumber numberWithUnsignedLongLong:e->batch];
    id<MTLLibrary> lib = loaded_libs[bid];
    if (!lib) {
        char path[700];
        snprintf(path, sizeof path, "%s/%016llx.metallib", libdir, (unsigned long long)e->batch);
        if (access(path, R_OK)) return nil;
        NSError *err = nil;
        lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] error:&err];
        if (!lib) { LOG_ONCE("cached library failed to load: %s", err.localizedDescription.UTF8String); return nil; }
        loaded_libs[bid] = lib;
        [lib release];
    }
    return [lib newFunctionWithName:[NSString stringWithFormat:@"s%d::main0", e->k]];
}

// after a batch compiled from source: index it and build its .metallib in the background
static void lib_cache_store(NSString *src, SJob **jobs, int n, const int *usable) {
    if (no_metallib()) return;
    const char *text = src.UTF8String;
    uint64_t bid = fnv64(1469598103934665603ull, text, strlen(text));
    char mpath[700], lpath[700];
    snprintf(mpath, sizeof mpath, "%s/%016llx.metal", libdir, (unsigned long long)bid);
    snprintf(lpath, sizeof lpath, "%s/%016llx.metallib", libdir, (unsigned long long)bid);
    if (access(lpath, R_OK)) {
        FILE *f = fopen(mpath, "w");
        if (!f) return;
        fputs(text, f);
        fclose(f);
        char *m = strdup(mpath), *l = strdup(lpath);
        dispatch_async(metallib_q, ^{
            dispatch_semaphore_wait(metallib_slots, DISPATCH_TIME_FOREVER);
            char tmp[720];
            snprintf(tmp, sizeof tmp, "%s.tmp", l);
            pid_t pid;
            char *argv[] = {"/usr/bin/xcrun", "-sdk", "macosx", "metal", "-fpreserve-invariance", "-o", tmp, m, NULL};
            extern char **environ;
            if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) == 0) {
                int st;
                waitpid(pid, &st, 0);
                if (WIFEXITED(st) && WEXITSTATUS(st) == 0) rename(tmp, l); else { unlink(tmp); LOG_ONCE("xcrun metal failed for %s", m); }
            }
            unlink(m);
            free(m); free(l);
            dispatch_semaphore_signal(metallib_slots);
        });
    }
    lock();
    for (int k = 0; k < n; k++)
        if (usable[k] && libidx_file) fprintf(libidx_file, "%016llx %016llx %d\n", (unsigned long long)jobs[k]->hash, (unsigned long long)bid, k);
    if (libidx_file) fflush(libidx_file);
    unlock();
}

// ---- batches ----
static void batch_append(NSMutableString *out, const char *msl, const char *ns) {
    [out appendFormat:@"namespace %s {\n", ns];
    for (const char *ln = msl; *ln; ) {
        const char *nl = strchr(ln, '\n');
        size_t n = nl ? (size_t)(nl - ln) : strlen(ln);
        if (strncmp(ln, "#include", 8) && strncmp(ln, "#pragma", 7) && strncmp(ln, "using namespace", 15))
            [out appendString:[[[NSString alloc] initWithBytes:ln length:n encoding:NSUTF8StringEncoding] autorelease]];
        [out appendString:@"\n"];
        ln = nl ? nl + 1 : ln + n;
    }
    [out appendString:@"}\n"];
}

#define BATCH 64
static SJob *pending[BATCH];
static int npending;
static uint32_t batch_epoch;

static void batch_compile(SJob **jobs, int n) {
    @autoreleasepool {
        NSMutableString *src = [NSMutableString stringWithString:
            @"#pragma clang diagnostic ignored \"-Wmissing-prototypes\"\n#pragma clang diagnostic ignored \"-Wmissing-braces\"\n"
            @"#include <metal_stdlib>\n#include <simd/simd.h>\nusing namespace metal;\n"];
        int usable[BATCH];
        for (int k = 0; k < n; k++) {
            usable[k] = 0;
            if (atomic_load(&jobs[k]->claimed)) continue;        // already compiled on demand
            char *msl = sj_msl(jobs[k]);
            if (!msl) continue;
            char ns[16];
            snprintf(ns, sizeof ns, "s%d", k);
            batch_append(src, msl, ns);
            free(msl);
            usable[k] = 1;
        }
        NSError *ne = nil;
        double t0 = now_ms();
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:compile_opts error:&ne];
        if (getenv("RT_METAL_DEBUG")) MGL_LOG("batch of %d shaders compiled in %.0f ms\n", n, now_ms() - t0);
        if (!lib) MGL_LOG("batch compile failed, compiling its shaders one by one: %s\n", ne.localizedDescription.UTF8String);
        else lib_cache_store(src, jobs, n, usable);
        for (int k = 0; k < n; k++) {
            SJob *j = jobs[k];
            if (atomic_exchange(&j->claimed, 1)) continue;
            id<MTLFunction> fn = lib && usable[k] ? [lib newFunctionWithName:[NSString stringWithFormat:@"s%d::main0", k]] : nil;
            if (fn) sj_finish(j, fn); else sj_compile_single(j);
        }
        [lib release];
    }
}

static void batch_flush(void) {                 // lock held
    if (!npending) return;
    SJob **jobs = malloc(sizeof(SJob *) * npending);
    int n = npending;
    memcpy(jobs, pending, sizeof(SJob *) * n);
    npending = 0;
    batch_epoch++;
    dispatch_async(compile_q, ^{
        dispatch_semaphore_wait(compile_slots, DISPATCH_TIME_FOREVER);
        batch_compile(jobs, n);
        dispatch_semaphore_signal(compile_slots);
        free(jobs);
    });
}

// the job for a stage with this source and attribute locations, created (and queued) if new; lock held
static SJob *stage_job(int stage, const char *src, const MglAttrib *attrs, int nattrs) {
    static const char conv_version[] = "mgl-conv-3";   // bump when mgl_to_msl's output changes
    uint64_t h = fnv64(1469598103934665603ull, conv_version, sizeof conv_version);
    h = fnv64(h, &stage, sizeof stage);
    h = fnv64(h, src, strlen(src));
    for (int a = 0; a < nattrs; a++) { h = fnv64(h, attrs[a].name, strlen(attrs[a].name)); h = fnv64(h, &attrs[a].location, 4); }
    SJob *j = sj_find(h);
    if (j) return j;
    j = calloc(1, sizeof *j);
    j->stage = stage; j->src = strdup(src); j->hash = h;
    memcpy(j->attrs, attrs, sizeof(MglAttrib) * nattrs); j->nattrs = nattrs;
    j->group = dispatch_group_create();
    dispatch_group_enter(j->group);
    sj_insert(j);
    id<MTLFunction> fn = lib_cache_load(h);
    if (fn) { atomic_store(&j->claimed, 1); sj_finish(j, fn); return j; }
    pending[npending++] = j;
    if (npending == BATCH) batch_flush();
    else {                                      // flush a partial batch once the burst pauses
        uint32_t epoch = batch_epoch;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), compile_q, ^{
            lock();
            if (batch_epoch == epoch) batch_flush();
            unlock();
        });
    }
    return j;
}

// vertex shader attributes in declaration order with locations: bound ones from `lookup`, the rest
// numbered after the highest bound location (GL leaves them to the implementation)
static int resolve_attrs(const char *src, int (*lookup)(void *, const char *), void *ctx, MglAttrib *out) {
    char names[16][64];
    int n = 0, next = 0;
    for (const char *s = src; (s = strstr(s, "attribute ")) && n < 16; ) {
        const char *nm = strchr(s + 10, ' ');
        if (!nm) break;
        nm++;
        int len = 0;
        while (nm[len] && nm[len] != ';' && nm[len] != ' ' && len < 63) { names[n][len] = nm[len]; len++; }
        names[n][len] = 0;
        n++;
        s = nm;
    }
    for (int k = 0; k < n; k++) { int l = lookup(ctx, names[k]); if (l >= next) next = l + 1; }
    for (int k = 0; k < n; k++) {
        snprintf(out[k].name, 64, "%s", names[k]);
        int l = lookup(ctx, names[k]);
        out[k].location = l >= 0 ? l : next++;
    }
    return n;
}
static int lookup_global(void *ctx, const char *name) { (void)ctx; return amap_get(name); }
static int lookup_prog(void *ctx, const char *name) {
    Prog *p = ctx;
    for (int a = 0; a < p->nattrs; a++) if (!strcmp(p->attrs[a].name, name)) return p->attrs[a].location;
    return -1;
}

// glShaderSource: start compiling (vertex shaders only when every attribute's location is known)
static void stage_precompile(Shader *sh) {
    int stage = sh->type == GL_VERTEX_SHADER ? MGL_VERTEX : MGL_FRAGMENT;
    MglAttrib attrs[16];
    int n = 0;
    if (stage == MGL_VERTEX) {
        n = resolve_attrs(sh->src, lookup_global, NULL, attrs);
        for (int k = 0; k < n; k++) if (amap_get(attrs[k].name) < 0) return;
    }
    stage_job(stage, sh->src, attrs, n);
}

static void prog_publish(Prog *p, GLuint name);

// glLinkProgram: look up (or queue) both stages; lock held
static void prog_link_stages(Prog *p, GLuint name) {
    MglAttrib attrs[16];
    int n = resolve_attrs(p->src[0], lookup_prog, p, attrs);
    for (int a = 0; a < p->nattrs; a++) amap_set(p->attrs[a].name, p->attrs[a].location);
    p->sj[0] = stage_job(MGL_VERTEX, p->src[0], attrs, n);
    p->sj[1] = stage_job(MGL_FRAGMENT, p->src[1], NULL, 0);
    p->hash = p->sj[0]->hash * 31 + p->sj[1]->hash;
    p->state = 1;
    if (atomic_load(&p->sj[0]->done) && atomic_load(&p->sj[1]->done)) prog_publish(p, name);
}

// both stages are compiled: take their functions
static void prog_publish(Prog *p, GLuint name) {
    (void)name;
    p->fn[0] = [p->sj[0]->fn retain];
    p->fn[1] = [p->sj[1]->fn retain];
    p->state = p->fn[0] && p->fn[1] ? 2 : 3;
}

// make sure a program's stages are compiled: compile a stage here unless a batch already took it
static int prog_ready(Prog *p) {
    if (p->state == 1) {
        double t0 = now_ms();
        unlock();
        for (int st = 0; st < 2; st++) {
            SJob *j = p->sj[st];
            if (atomic_load(&j->done)) continue;
            if (!atomic_exchange(&j->claimed, 1)) sj_compile_single(j);
            else dispatch_group_wait(j->group, DISPATCH_TIME_FOREVER);
        }
        lock();
        if (p->state == 1) prog_publish(p, p->name);
        hz.progwait += now_ms() - t0; hz.nprogwait++;
    }
    return p->state == 2;
}

// ---------- draws ----------
static MTLVertexFormat vfmt(const Attrib *a) {
    int n = a->size;
    switch (a->type) {
        case GL_FLOAT: return n == 1 ? MTLVertexFormatFloat : n == 2 ? MTLVertexFormatFloat2 : n == 3 ? MTLVertexFormatFloat3 : MTLVertexFormatFloat4;
        case GL_HALF_FLOAT: return n == 1 ? MTLVertexFormatHalf : n == 2 ? MTLVertexFormatHalf2 : n == 3 ? MTLVertexFormatHalf3 : MTLVertexFormatHalf4;
        case GL_UNSIGNED_BYTE:
            if (n == GL_BGRA) return MTLVertexFormatUChar4Normalized_BGRA;
            if (a->normalized) return n == 2 ? MTLVertexFormatUChar2Normalized : n == 3 ? MTLVertexFormatUChar3Normalized : MTLVertexFormatUChar4Normalized;
            return n == 2 ? MTLVertexFormatUChar2 : n == 3 ? MTLVertexFormatUChar3 : MTLVertexFormatUChar4;
        case GL_SHORT:
            if (a->normalized) return n == 2 ? MTLVertexFormatShort2Normalized : n == 3 ? MTLVertexFormatShort3Normalized : MTLVertexFormatShort4Normalized;
            return n == 2 ? MTLVertexFormatShort2 : n == 3 ? MTLVertexFormatShort3 : MTLVertexFormatShort4;
        case GL_UNSIGNED_SHORT:
            if (a->normalized) return n == 2 ? MTLVertexFormatUShort2Normalized : n == 3 ? MTLVertexFormatUShort3Normalized : MTLVertexFormatUShort4Normalized;
            return n == 2 ? MTLVertexFormatUShort2 : n == 3 ? MTLVertexFormatUShort3 : MTLVertexFormatUShort4;
        default: LOG_ONCE("vertex type 0x%x size %d", a->type, n); return MTLVertexFormatFloat4;
    }
}
static int vsize(const Attrib *a) {
    int n = a->size == GL_BGRA ? 4 : a->size;
    int t = a->type == GL_FLOAT ? 4 : (a->type == GL_HALF_FLOAT || a->type == GL_SHORT || a->type == GL_UNSIGNED_SHORT) ? 2 : 1;
    return n * t;
}

static void apply_dynamic_state(void) {
    MTLViewport vp = {S.viewport[0], S.viewport[1], S.viewport[2], S.viewport[3], S.depth_near, S.depth_far};
    if (!es.has_vp || memcmp(&vp, &es.vp, sizeof vp)) { [enc setViewport:vp]; es.vp = vp; es.has_vp = 1; }
    int tw = cur_t.color[0] ? (int)cur_t.color[0].width >> cur_t.level[0] : cur_t.depth ? (int)cur_t.depth.width : 1;
    int th = cur_t.color[0] ? (int)cur_t.color[0].height >> cur_t.level[0] : cur_t.depth ? (int)cur_t.depth.height : 1;
    MTLScissorRect sc = {0, 0, tw, th};
    if (S.scissor_test) {
        int x0 = S.scissor[0] < 0 ? 0 : S.scissor[0], y0 = S.scissor[1] < 0 ? 0 : S.scissor[1];
        int x1 = S.scissor[0] + S.scissor[2], y1 = S.scissor[1] + S.scissor[3];
        if (x1 > tw) x1 = tw;
        if (y1 > th) y1 = th;
        if (x0 > x1) x0 = x1;
        if (y0 > y1) y0 = y1;
        sc = (MTLScissorRect){x0, y0, x1 - x0, y1 - y0};
    }
    if (!es.has_sc || memcmp(&sc, &es.sc, sizeof sc)) { [enc setScissorRect:sc]; es.sc = sc; es.has_sc = 1; }
    int cull = S.cull ? (S.cull_face == GL_FRONT ? 1 : S.cull_face == GL_BACK ? 2 : 3) : 0;
    if (cull != es.cull) {
        [enc setCullMode:cull == 1 ? MTLCullModeFront : cull == 2 ? MTLCullModeBack : MTLCullModeNone];
        es.cull = cull;
    }
    static int winding = -1;
    if (winding < 0) winding = getenv("RT_METAL_CCW") ? 1 : 0;   // GL CCW front faces appear clockwise after the Y flip
    if (es.winding != winding) {
        [enc setFrontFacingWinding:winding ? MTLWindingCounterClockwise : MTLWindingClockwise];
        es.winding = winding;
    }
    if (S.stencil_test && (es.stencil_ref_f != S.sf[0].ref || es.stencil_ref_b != S.sf[1].ref)) {
        [enc setStencilFrontReferenceValue:S.sf[0].ref backReferenceValue:S.sf[1].ref];
        es.stencil_ref_f = S.sf[0].ref; es.stencil_ref_b = S.sf[1].ref;
    }
    float bias[3] = {S.poly_offset ? S.offset_units : 0, S.poly_offset ? S.offset_factor : 0, 0};
    if (memcmp(bias, es.bias, sizeof bias)) { [enc setDepthBias:bias[0] slopeScale:bias[1] clamp:0]; memcpy(es.bias, bias, sizeof bias); }
    [enc setTriangleFillMode:S.poly_mode == GL_LINE ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    int vm = S.active_query ? 1 : 0;
    uint32_t off = 0;
    if (vm) {
        Query *q = queries[S.active_query];
        if (q && !q->nslots) query_slot_for_pass();
        off = q && q->nslots ? q->slot[q->nslots - 1] * 8 : 0;
    }
    if (vm != es.vis_mode || off != es.vis_off) {
        [enc setVisibilityResultMode:vm ? MTLVisibilityResultModeCounting : MTLVisibilityResultModeDisabled offset:off];
        es.vis_mode = vm; es.vis_off = off;
    }
}

// a query gets a fresh visibility slot for every render pass it spans (summed on readback)
static void query_slot_for_pass(void) {
    if (!S.active_query) return;
    Query *q = queries[S.active_query];
    if (!q) return;
    if (q->nslots == 8) { LOG_ONCE("query spans more than 8 passes"); return; }
    if (vis_next >= VIS_SLOTS) { LOG_ONCE("visibility buffer full"); return; }
    q->slot[q->nslots++] = vis_next++;
    q->serial = serial; q->frame = frame_index;
}

static id<MTLTexture> unit_texture(int unit, int cube, id<MTLSamplerState> *smp) {
    Tex *t = tex_of(cube ? S.texcube[unit] : S.tex2d[unit]);
    if (!t || !t->mt || t->maxlev_uploaded < 0 && !(t->mt.usage & MTLTextureUsageRenderTarget)) {
        *smp = dummy_samp;
        return cube ? dummycube : dummy2d;
    }
    t->used = serial;
    *smp = sampler_for(t);
    if (passlog_on && (t->mt.usage & MTLTextureUsageRenderTarget)) PLOG("  sample t%d\n", tid(t->mt));
    else if (passlog_on) PLOG("  sample tex %u %lux%lu fmt %lu mips %lu\n", cube ? S.texcube[unit] : S.tex2d[unit],
                              (unsigned long)t->mt.width, (unsigned long)t->mt.height, (unsigned long)t->mt.pixelFormat,
                              (unsigned long)t->mt.mipmapLevelCount);
    return t->mt;
}

// common draw path; returns 0 when the draw must be skipped
static int prepare_draw(int vtx_first, int vtx_end, int instanced) {
    Prog *p = S.prog && S.prog < NAMES ? progs[S.prog] : NULL;
    if (!p) { LOG_ONCE("draw without a program"); return 0; }
    if (!prog_ready(p)) return 0;
    if (npcs)                                   // textures this draw samples must have their clears done
        for (int st = 0; st < 2; st++)
            for (int sm = 0; sm < p->nsamp[st]; sm++) {
                int u = p->unit[st][sm] & 15;
                Tex *tt = tex_of(p->skind[st][sm] == MGL_SAMPLERCUBE ? S.texcube[u] : S.tex2d[u]);
                if (tt && tt->mt) pc_flush(tt->mt);
            }
    ensure_pass(0);
    if (!enc) return 0;
    PipeKey k;
    memset(&k, 0, sizeof k);
    k.vsh = p->sj[0]->hash; k.fsh = p->sj[1]->hash;
    // vertex inputs
    id<MTLBuffer> vb[16];
    size_t voff[16];
    for (int l = 0; l < 16; l++) {
        vb[l] = nil; voff[l] = 0;
        if (!(p->attr_used & (1u << l))) continue;
        Attrib *a = &S.attr[l];
        if (!a->enabled) {
            k.vfmt[l] = MTLVertexFormatFloat4; k.vstep[l] = MTLVertexStepFunctionConstant; k.vstride[l] = 0;
            vb[l] = zero_attr;
            continue;
        }
        int stride = a->stride ? a->stride : vsize(a);
        k.vfmt[l] = vfmt(a);
        k.vstride[l] = stride;
        k.vstep[l] = a->divisor ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex;
        k.vdiv[l] = a->divisor;
        Buf *b = a->buffer && a->buffer < NAMES ? bufs[a->buffer] : NULL;
        if (b && b->mb) { vb[l] = b->mb; voff[l] = a->ptr; b->used = serial; }
        else if (!a->buffer && a->ptr) {          // client-side array: copy the vertices the draw reads
            int n = a->divisor ? (instanced ? instanced : 1) : vtx_end;
            size_t bytes = (size_t)n * stride + 16;
            id<MTLBuffer> rb;
            size_t ro;
            void *dst = ring_alloc(bytes, &rb, &ro);
            memcpy(dst, (const void *)a->ptr, (size_t)n * stride);
            vb[l] = rb; voff[l] = ro;
        } else { LOG_ONCE("attribute %d has no data", l); vb[l] = zero_attr; k.vstep[l] = MTLVertexStepFunctionConstant; k.vfmt[l] = MTLVertexFormatFloat4; k.vstride[l] = 0; }
    }
    (void)vtx_first;
    for (int c = 0; c < cur_t.ncolor; c++) if (cur_t.color[c]) k.cfmt[c] = cur_t.color[c].pixelFormat;
    k.dfmt = cur_t.depth ? cur_t.depth.pixelFormat : 0;
    k.sfmt = cur_t.stencil ? cur_t.stencil.pixelFormat : 0;
    k.wmask = S.color_mask;
    if (S.blend) {
        k.blend = 1;
        k.bsrc_rgb = S.bsrc_rgb; k.bdst_rgb = S.bdst_rgb; k.bsrc_a = S.bsrc_a; k.bdst_a = S.bdst_a;
        k.beq_rgb = S.beq_rgb; k.beq_a = S.beq_a;
    }
    id<MTLRenderPipelineState> pipe = pipeline(&k, p->fn[0], p->fn[1]);
    if (!pipe) return 0;
    if (pipe != es.pipe) { [enc setRenderPipelineState:pipe]; es.pipe = pipe; }
    id<MTLDepthStencilState> ds = ds_state(cur_t.depth != nil, cur_t.stencil != nil);
    if (ds != es.ds) { [enc setDepthStencilState:ds]; es.ds = ds; }
    apply_dynamic_state();
    for (int l = 0; l < 16; l++) if (vb[l]) [enc setVertexBuffer:vb[l] offset:voff[l] atIndex:1 + l];
    pass_draws++;
    PLOG("  draw viewport %d,%d %dx%d scissor %d prog %u fs %016llx\n", S.viewport[0], S.viewport[1], S.viewport[2], S.viewport[3],
         S.scissor_test, S.prog, (unsigned long long)p->sj[1]->hash);
    if (p->bias_off >= 0) {                     // GL texture-unit LOD bias of each fragment sampler
        float b[16] = {0};
        static int sharpen = -1;
        if (sharpen < 0) sharpen = getenv("RT_METAL_SHARPEN") != 0;   // experimental: thresholded mask alpha
        for (int sm = 0; sm < p->nsamp[1] && sm < 16; sm++) {
            int u = p->unit[1][sm] & 15;
            b[sm] = S.lod_bias[u];
            Tex *t = p->skind[1][sm] == MGL_SAMPLERCUBE ? NULL : tex_of(S.tex2d[u]);
            if (sharpen && t && t->mask) b[sm] += 1024;          // SC_Tex2D sharpens its alpha (mgl_shader.cpp)
        }
        memcpy(p->block[1] + p->bias_off, b, sizeof b);
        static int dbg = -1;
        if (dbg < 0) dbg = getenv("RT_METAL_DEBUG") != 0;
        if (dbg)
            for (int sm = 0; sm < p->nsamp[1] && sm < 16; sm++)
                if (b[sm] != 0 && b[sm] < 512) LOG_ONCE("LOD bias %g on sampler %d of fragment shader %016llx (%dx%d target)", b[sm], sm,
                                         (unsigned long long)p->sj[1]->hash, cur_t.color[0] ? (int)cur_t.color[0].width : 0,
                                         cur_t.color[0] ? (int)cur_t.color[0].height : 0);
    }
    // uniforms
    for (int st = 0; st < 2; st++) {
        if (!p->bsize[st]) continue;
        id<MTLBuffer> ub;
        size_t uo;
        void *dst = ring_alloc(p->bsize[st], &ub, &uo);
        memcpy(dst, p->block[st], p->bsize[st]);
        if (st == 0) [enc setVertexBuffer:ub offset:uo atIndex:0];
        else [enc setFragmentBuffer:ub offset:uo atIndex:0];
    }
    // textures
    for (int st = 0; st < 2; st++)
        for (int s = 0; s < p->nsamp[st]; s++) {
            id<MTLSamplerState> smp;
            id<MTLTexture> t = unit_texture(p->unit[st][s] & 15, p->skind[st][s] == MGL_SAMPLERCUBE, &smp);
            if (st == 0) { [enc setVertexTexture:t atIndex:s]; [enc setVertexSamplerState:smp atIndex:s]; }
            else { [enc setFragmentTexture:t atIndex:s]; [enc setFragmentSamplerState:smp atIndex:s]; }
        }
    return 1;
}

static MTLPrimitiveType prim(GLenum mode, int *ok) {
    *ok = 1;
    switch (mode) {
        case GL_POINTS: return MTLPrimitiveTypePoint;
        case GL_LINES: return MTLPrimitiveTypeLine;
        case GL_LINE_STRIP: return MTLPrimitiveTypeLineStrip;
        case GL_TRIANGLES: return MTLPrimitiveTypeTriangle;
        case GL_TRIANGLE_STRIP: return MTLPrimitiveTypeTriangleStrip;
        default: *ok = 0; LOG_ONCE("primitive mode 0x%x", mode); return MTLPrimitiveTypeTriangle;
    }
}

// ---------- GL entry points ----------
#define GLFN(ret, name, ...) ret mgl_##name(__VA_ARGS__)
#define STUB(name) LOG_ONCE(#name " not implemented")

GLFN(void, glActiveTexture, GLenum t) { lock(); S.unit = (t - GL_TEXTURE0) & 15; unlock(); }
GLFN(void, glAlphaFunc, GLenum f, GLfloat ref) { lock(); S.alpha_func = f; S.alpha_ref = ref; unlock(); }
GLFN(void, glAttachShader, GLuint p, GLuint s) {
    lock();
    Prog *pr = p < NAMES ? progs[p] : NULL;
    Shader *sh = s < NAMES ? shaders[s] : NULL;
    if (pr && sh) { if (sh->type == GL_VERTEX_SHADER) pr->vs = s; else pr->fs = s; }
    unlock();
}
GLFN(void, glBegin, GLenum mode) { lock(); S.in_begin = mode; S.nimm = 0; unlock(); }
GLFN(void, glBeginQuery, GLenum target, GLuint id) {
    (void)target;
    lock();
    Query *q = id < NAMES ? queries[id] : NULL;
    if (q) { q->nslots = 0; q->serial = serial; q->frame = frame_index; S.active_query = id; if (enc) query_slot_for_pass(); }
    unlock();
}
GLFN(void, glBindAttribLocation, GLuint p, GLuint idx, const char *name) {
    lock();
    Prog *pr = p < NAMES ? progs[p] : NULL;
    if (pr && pr->nattrs < 16) {
        int k;
        for (k = 0; k < pr->nattrs; k++) if (!strcmp(pr->attrs[k].name, name)) break;
        if (k == pr->nattrs) pr->nattrs++;
        snprintf(pr->attrs[k].name, sizeof pr->attrs[k].name, "%s", name);
        pr->attrs[k].location = idx;
    }
    unlock();
}
GLFN(void, glBindBuffer, GLenum target, GLuint b) {
    lock();
    if (b && b < NAMES && !bufs[b]) bufs[b] = calloc(1, sizeof(Buf));
    if (target == GL_ARRAY_BUFFER) S.array_buf = b;
    else if (target == GL_ELEMENT_ARRAY_BUFFER) S.elem_buf = b;
    else if (target == GL_PIXEL_UNPACK_BUFFER) S.unpack_buf = b;
    else LOG_ONCE("glBindBuffer target 0x%x", target);
    unlock();
}
GLFN(void, glBindFramebuffer, GLenum target, GLuint f) {
    lock();
    if (f && f < NAMES && !fbos[f]) fbos[f] = calloc(1, sizeof(Fbo));
    if (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER) S.draw_fbo = f;
    if (target == GL_FRAMEBUFFER || target == GL_READ_FRAMEBUFFER) S.read_fbo = f;
    unlock();
}
GLFN(void, glBindRenderbuffer, GLenum target, GLuint r) {
    (void)target;
    lock();
    if (r && r < NAMES && !rbs[r]) rbs[r] = calloc(1, sizeof(Rb));
    S.rb = r;
    unlock();
}
static Tex *new_tex(GLenum target) {
    Tex *t = calloc(1, sizeof(Tex));
    t->target = target;
    t->min_f = GL_NEAREST_MIPMAP_LINEAR; t->mag_f = GL_LINEAR;
    t->wrap_s = t->wrap_t = GL_REPEAT;
    t->max_level = 1000; t->aniso = 1;
    t->maxlev_uploaded = -1;
    return t;
}
GLFN(void, glBindTexture, GLenum target, GLuint t) {
    lock();
    if (t && t < NAMES && !texs[t]) texs[t] = new_tex(target);
    if (target == GL_TEXTURE_CUBE_MAP) S.texcube[S.unit] = t; else S.tex2d[S.unit] = t;
    if (t && texs[t]) texs[t]->target = target;
    unlock();
}
GLFN(void, glBlendEquation, GLenum e) { lock(); S.beq_rgb = S.beq_a = e; unlock(); }
GLFN(void, glBlendEquationSeparate, GLenum rgb, GLenum a) { lock(); S.beq_rgb = rgb; S.beq_a = a; unlock(); }
GLFN(void, glBlendFunc, GLenum s, GLenum d) { lock(); S.bsrc_rgb = S.bsrc_a = s; S.bdst_rgb = S.bdst_a = d; unlock(); }
GLFN(void, glBlendFuncSeparate, GLenum sr, GLenum dr, GLenum sa, GLenum da) {
    lock(); S.bsrc_rgb = sr; S.bdst_rgb = dr; S.bsrc_a = sa; S.bdst_a = da; unlock();
}

// read framebuffer colour 0 as a texture (for blits)
static id<MTLTexture> read_color(int *level, int *slice) {
    *level = 0; *slice = 0;
    if (!S.read_fbo) { ensure_backbuffer(); return back_color; }
    Fbo *f = fbos[S.read_fbo];
    return f ? att_texture(&f->color[0], level, slice) : nil;
}

GLFN(void, glBlitFramebuffer, GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0, GLint dx1, GLint dy1,
     GLbitfield mask, GLenum filter) {
    lock();
    if (mask & (GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) LOG_ONCE("depth/stencil blit not implemented");
    if (mask & GL_COLOR_BUFFER_BIT) {
        int sl, ss;
        id<MTLTexture> src = read_color(&sl, &ss);
        PLOG("blit from t%d (%d,%d-%d,%d -> %d,%d-%d,%d)\n", tid(src), sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1);
        if (src && sl == 0 && ss == 0) {
            pc_flush(src);
            // a blit that covers the whole destination does not need its old contents
            Target dt;
            current_target(&dt);
            int dw = dt.color[0] ? (int)dt.color[0].width >> dt.level[0] : 0, dh = dt.color[0] ? (int)dt.color[0].height >> dt.level[0] : 0;
            int full = dt.ncolor == 1 && !S.scissor_test && ((dx0 == 0 && dx1 == dw) || (dx1 == 0 && dx0 == dw)) &&
                       ((dy0 == 0 && dy1 == dh) || (dy1 == 0 && dy0 == dh));
            ensure_pass_ex(0, full);
            if (enc && cur_t.color[0] && cur_t.color[0] != src) {
                int sw = (int)src.width, sh = (int)src.height;
                int tw = (int)cur_t.color[0].width >> cur_t.level[0], th = (int)cur_t.color[0].height >> cur_t.level[0];
                // corners: destination in Metal NDC (row 0 at NDC y +1), source in texture coordinates
                float x0 = 2.0f * dx0 / tw - 1, x1 = 2.0f * dx1 / tw - 1;
                float y0 = 1 - 2.0f * dy0 / th, y1 = 1 - 2.0f * dy1 / th;
                float u0 = (float)sx0 / sw, u1 = (float)sx1 / sw, v0 = (float)sy0 / sh, v1 = (float)sy1 / sh;
                float v[4][4] = {{x0, y0, u0, v0}, {x1, y0, u1, v0}, {x0, y1, u0, v1}, {x1, y1, u1, v1}};
                MTLViewport vp = {0, 0, tw, th, 0, 1};
                [enc setViewport:vp];
                [enc setScissorRect:(MTLScissorRect){0, 0, tw, th}];
                es.has_vp = es.has_sc = 0;
                internal_quad(1, internal_fn[FN_COPY_FS], src, filter == GL_LINEAR ? samp_linear : samp_nearest, v, NULL);
            } else if (cur_t.color[0] == src) LOG_ONCE("blit within one texture");
        } else LOG_ONCE("blit from a texture level/face");
    }
    unlock();
}

GLFN(void, glBufferData, GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
    (void)usage;
    lock();
    Buf *b = buf_bound(target);
    if (b) buf_alloc(b, size, data, 0);
    unlock();
}
GLFN(void, glBufferParameteriAPPLE, GLenum target, GLenum pname, GLint param) { (void)target; (void)pname; (void)param; }
// clear by drawing: honours the scissor rectangle and the colour, depth and stencil write masks
static void clear_by_draw(GLbitfield mask) {
    PipeKey k;
    memset(&k, 0, sizeof k);
    k.kind = 4;
    for (int c = 0; c < cur_t.ncolor; c++) if (cur_t.color[c]) k.cfmt[c] = cur_t.color[c].pixelFormat;
    k.dfmt = cur_t.depth ? cur_t.depth.pixelFormat : 0;
    k.sfmt = cur_t.stencil ? cur_t.stencil.pixelFormat : 0;
    k.wmask = (mask & GL_COLOR_BUFFER_BIT) ? S.color_mask : 0;
    k.kind = cur_t.depth ? 4 : 5;
    id<MTLRenderPipelineState> p = pipeline(&k, internal_fn[FN_QUAD_VS], internal_fn[cur_t.depth ? FN_CLEAR_FS : FN_CLEAR_COLOR_FS]);
    if (!p) return;
    DsKey dk;
    memset(&dk, 0, sizeof dk);
    dk.depth_func = GL_ALWAYS;
    if (cur_t.depth && (mask & GL_DEPTH_BUFFER_BIT)) { dk.depth_test = 1; dk.depth_write = 1; }
    if (cur_t.stencil && (mask & GL_STENCIL_BUFFER_BIT)) {
        dk.stencil = 1; dk.wmask = S.stencil_wmask;
        for (int f = 0; f < 2; f++) { dk.f[f].func = GL_ALWAYS; dk.f[f].fail = dk.f[f].zfail = dk.f[f].zpass = GL_REPLACE; dk.f[f].mask = ~0u; }
    }
    [enc setRenderPipelineState:p]; es.pipe = p;
    [enc setDepthStencilState:ds_lookup(dk)]; es.ds = nil;
    [enc setCullMode:MTLCullModeNone]; es.cull = -1;
    [enc setStencilReferenceValue:S.clear_stencil]; es.stencil_ref_f = es.stencil_ref_b = -1;
    // full viewport, GL scissor
    GLint vp[4];
    memcpy(vp, S.viewport, sizeof vp);
    int tw = cur_t.color[0] ? (int)cur_t.color[0].width >> cur_t.level[0] : cur_t.depth ? (int)cur_t.depth.width : 1;
    int th = cur_t.color[0] ? (int)cur_t.color[0].height >> cur_t.level[0] : cur_t.depth ? (int)cur_t.depth.height : 1;
    S.viewport[0] = 0; S.viewport[1] = 0; S.viewport[2] = tw; S.viewport[3] = th;
    float dn = S.depth_near, df = S.depth_far;
    S.depth_near = 0; S.depth_far = 1;
    apply_dynamic_state();
    memcpy(S.viewport, vp, sizeof vp);
    S.depth_near = dn; S.depth_far = df;
    es.has_vp = 0;                                // restore the game's viewport on the next draw
    // the clear's fragments must not count towards an open occlusion query
    [enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    es.vis_mode = -1;
    [enc setCullMode:MTLCullModeNone]; es.cull = -1;
    float v[4][4] = {{-1, -1, 0, 0}, {1, -1, 0, 0}, {-1, 1, 0, 0}, {1, 1, 0, 0}};
    float params[8] = {S.clear_color[0], S.clear_color[1], S.clear_color[2], S.clear_color[3], S.clear_depth, 0, 0, 0};
    [enc setVertexBytes:v length:sizeof v atIndex:0];
    [enc setFragmentBytes:params length:sizeof params atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

GLFN(void, glClear, GLbitfield mask) {
    lock();
    if (!S.depth_mask) mask &= ~GL_DEPTH_BUFFER_BIT;           // glClear honours the write masks
    if (!(S.stencil_wmask & 0xff)) mask &= ~GL_STENCIL_BUFFER_BIT;
    if (!S.color_mask) mask &= ~GL_COLOR_BUFFER_BIT;
    if (mask) {
        Target t;
        current_target(&t);
        int tw = t.color[0] ? (int)t.color[0].width >> t.level[0] : t.depth ? (int)t.depth.width : 0;
        int th = t.color[0] ? (int)t.color[0].height >> t.level[0] : t.depth ? (int)t.depth.height : 0;
        int partial = (S.scissor_test && (S.scissor[0] > 0 || S.scissor[1] > 0 || S.scissor[0] + S.scissor[2] < tw ||
                                          S.scissor[1] + S.scissor[3] < th)) ||
                      ((mask & GL_COLOR_BUFFER_BIT) && S.color_mask != 15) ||
                      ((mask & GL_STENCIL_BUFFER_BIT) && (S.stencil_wmask & 0xff) != 0xff);
        int open_here = enc && cur_t_valid && same_target(&t, &cur_t);
        if (partial || open_here) {
            ensure_pass(0);
            if (enc) clear_by_draw(mask);
        } else if (!getenv("RT_METAL_DEFER")) ensure_pass(mask);   // deferral measured no gain: opt-in
        else {                                    // defer: the next pass on these textures clears them
            if (mask & GL_COLOR_BUFFER_BIT) for (int k = 0; k < t.ncolor; k++) pc_add(t.color[k], t.level[k], t.slice[k], PC_COLOR);
            if (mask & GL_DEPTH_BUFFER_BIT) pc_add(t.depth, 0, 0, PC_DEPTH);
            if (mask & GL_STENCIL_BUFFER_BIT) pc_add(t.stencil, 0, 0, PC_STENCIL);
        }
    }
    unlock();
}
GLFN(void, glClearColor, GLfloat r, GLfloat g, GLfloat b, GLfloat a) {
    lock(); S.clear_color[0] = r; S.clear_color[1] = g; S.clear_color[2] = b; S.clear_color[3] = a; unlock();
}
GLFN(void, glClearDepth, GLdouble d) { lock(); S.clear_depth = d; unlock(); }
GLFN(void, glClearStencil, GLint s) { lock(); S.clear_stencil = s; unlock(); }
GLFN(void, glColorMask, GLboolean r, GLboolean g, GLboolean b, GLboolean a) {
    lock(); S.color_mask = (r ? 1 : 0) | (g ? 2 : 0) | (b ? 4 : 0) | (a ? 8 : 0); unlock();
}
GLFN(void, glCompileShader, GLuint s) { (void)s; }

static void tex_image(GLenum target, GLint level, GLenum ifmt, GLsizei w, GLsizei h, const void *data, size_t size,
                      GLenum format, GLenum type, int compressed) {
    GLenum base;
    int face = face_of(target, &base);
    Tex *t = tex_of(bound_tex_name(base));
    if (!t) return;
    t->target = base;
    if (level == 0 || !t->mt) tex_storage(t, ifmt, level, w, h);
    else if (t->ifmt != ifmt) { LOG_ONCE("level %d format 0x%x differs from 0x%x", level, ifmt, t->ifmt); return; }
    if (data) tex_upload(t, level, face, 0, 0, w, h, data, size, format, type, compressed);
    t->used = 0;
}
GLFN(void, glCompressedTexImage2D, GLenum target, GLint level, GLenum ifmt, GLsizei w, GLsizei h, GLint border,
     GLsizei size, const void *data) {
    (void)border;
    lock();
    tex_image(target, level, ifmt, w, h, data ? unpack_ptr((uint64_t)data) : (S.unpack_buf ? unpack_ptr(0) : NULL), size, 0, 0, 1);
    unlock();
}
GLFN(void, glCompressedTexSubImage2D, GLenum target, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum fmt,
     GLsizei size, const void *data) {
    (void)fmt;
    lock();
    GLenum base;
    int face = face_of(target, &base);
    Tex *t = tex_of(bound_tex_name(base));
    const void *p = (data || S.unpack_buf) ? unpack_ptr((uint64_t)data) : NULL;
    if (t && p) tex_upload(t, level, face, x, y, w, h, p, size, 0, 0, 1);
    unlock();
}
GLFN(GLuint, glCreateProgram, void) {
    lock();
    GLuint n = gen_name(P_OBJ);
    if (n) progs[n] = calloc(1, sizeof(Prog));
    unlock();
    return n;
}
GLFN(GLuint, glCreateShader, GLenum type) {
    lock();
    GLuint n = gen_name(P_OBJ);
    if (n) { shaders[n] = calloc(1, sizeof(Shader)); shaders[n]->type = type; }
    unlock();
    return n;
}
GLFN(void, glCullFace, GLenum f) { lock(); S.cull_face = f; unlock(); }
GLFN(void, glDeleteBuffers, GLsizei n, const GLuint *b) {
    lock();
    for (int k = 0; k < n; k++) {
        GLuint x = b[k];
        if (!x || x >= NAMES || !bufs[x]) continue;
        if (bufs[x]->mb) [bufs[x]->mb release];
        free(bufs[x]); bufs[x] = NULL; free_name(P_BUF, x);
        if (S.array_buf == x) S.array_buf = 0;
        if (S.elem_buf == x) S.elem_buf = 0;
        if (S.unpack_buf == x) S.unpack_buf = 0;
    }
    unlock();
}
GLFN(void, glDeleteFramebuffers, GLsizei n, const GLuint *f) {
    lock();
    for (int k = 0; k < n; k++) {
        GLuint x = f[k];
        if (!x || x >= NAMES || !fbos[x]) continue;
        free(fbos[x]); fbos[x] = NULL; free_name(P_FBO, x);
        if (S.draw_fbo == x) S.draw_fbo = 0;
        if (S.read_fbo == x) S.read_fbo = 0;
    }
    unlock();
}
GLFN(void, glDeleteProgram, GLuint p) {
    lock();
    if (p && p < NAMES && progs[p]) {
        Prog *pr = progs[p];
        pr->gen++;                       // pipelines still warming are discarded
        if (pr->warm) { unlock(); dispatch_group_wait(pr->warm, DISPATCH_TIME_FOREVER); lock(); dispatch_release(pr->warm); }
        [pr->fn[0] release]; [pr->fn[1] release];
        free(pr->src[0]); free(pr->src[1]); free(pr->block[0]); free(pr->block[1]);
        free(pr); progs[p] = NULL; free_name(P_OBJ, p);
        if (S.prog == p) S.prog = 0;
    }
    unlock();
}
GLFN(void, glDeleteQueries, GLsizei n, const GLuint *q) {
    lock();
    for (int k = 0; k < n; k++) if (q[k] && q[k] < NAMES && queries[q[k]]) { free(queries[q[k]]); queries[q[k]] = NULL; free_name(P_QUERY, q[k]); }
    unlock();
}
GLFN(void, glDeleteRenderbuffers, GLsizei n, const GLuint *r) {
    lock();
    for (int k = 0; k < n; k++) {
        GLuint x = r[k];
        if (!x || x >= NAMES || !rbs[x]) continue;
        if (rbs[x]->mt) [rbs[x]->mt release];
        free(rbs[x]); rbs[x] = NULL; free_name(P_RB, x);
    }
    unlock();
}
GLFN(void, glDeleteShader, GLuint s) {
    lock();
    if (s && s < NAMES && shaders[s]) { free(shaders[s]->src); free(shaders[s]); shaders[s] = NULL; free_name(P_OBJ, s); }
    unlock();
}
GLFN(void, glDeleteTextures, GLsizei n, const GLuint *t) {
    lock();
    for (int k = 0; k < n; k++) {
        GLuint x = t[k];
        if (!x || x >= NAMES || !texs[x]) continue;
        if (texs[x]->mt) [texs[x]->mt release];
        if (texs[x]->samp) [texs[x]->samp release];
        free(texs[x]); texs[x] = NULL; free_name(P_TEX, x);
        for (int u = 0; u < 16; u++) { if (S.tex2d[u] == x) S.tex2d[u] = 0; if (S.texcube[u] == x) S.texcube[u] = 0; }
    }
    unlock();
}
GLFN(void, glDepthFunc, GLenum f) { lock(); S.depth_func = f; unlock(); }
GLFN(void, glDepthMask, GLboolean m) { lock(); S.depth_mask = m; unlock(); }
GLFN(void, glDepthRange, GLdouble n, GLdouble f) { lock(); S.depth_near = n; S.depth_far = f; unlock(); }
static void set_cap(GLenum cap, int on) {
    switch (cap) {
        case GL_BLEND: S.blend = on; break;
        case GL_CULL_FACE: S.cull = on; break;
        case GL_DEPTH_TEST: S.depth_test = on; break;
        case GL_STENCIL_TEST: S.stencil_test = on; break;
        case GL_SCISSOR_TEST: S.scissor_test = on; break;
        case GL_POLYGON_OFFSET_FILL: S.poly_offset = on; break;
        case GL_ALPHA_TEST_: S.alpha_test = on; break;
        case GL_TEXTURE_2D: S.tex2d_enabled = on; break;
        case GL_DITHER: break;
        default: LOG_ONCE("glEnable/glDisable 0x%x", cap);
    }
}
GLFN(void, glDisable, GLenum cap) { lock(); set_cap(cap, 0); unlock(); }
GLFN(void, glEnable, GLenum cap) { lock(); set_cap(cap, 1); unlock(); }
GLFN(void, glDisableVertexAttribArray, GLuint i) { lock(); if (i < 16) S.attr[i].enabled = 0; unlock(); }
GLFN(void, glEnableVertexAttribArray, GLuint i) { lock(); if (i < 16) S.attr[i].enabled = 1; unlock(); }

static void draw_indexed(GLenum mode, GLsizei count, GLenum type, const void *indices, GLuint end, int instances) {
    int ok;
    MTLPrimitiveType pt = prim(mode, &ok);
    if (!ok || count <= 0) return;
    if (!prepare_draw(0, end + 1, instances)) return;
    MTLIndexType it = type == GL_UNSIGNED_INT ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
    if (type == GL_UNSIGNED_BYTE) { LOG_ONCE("8-bit indices"); return; }
    size_t isz = type == GL_UNSIGNED_INT ? 4 : 2;
    Buf *eb = S.elem_buf && S.elem_buf < NAMES ? bufs[S.elem_buf] : NULL;
    id<MTLBuffer> ib;
    size_t ioff;
    if (eb && eb->mb) { ib = eb->mb; ioff = (size_t)indices; eb->used = serial; }
    else {
        void *dst = ring_alloc(count * isz, &ib, &ioff);
        memcpy(dst, indices, count * isz);
    }
    if (ioff % isz) {                   // Metal needs aligned index offsets: copy
        id<MTLBuffer> nb;
        size_t no;
        void *dst = ring_alloc(count * isz, &nb, &no);
        memcpy(dst, (uint8_t *)[ib contents] + ioff, count * isz);
        ib = nb; ioff = no;
    }
    if (instances > 1)
        [enc drawIndexedPrimitives:pt indexCount:count indexType:it indexBuffer:ib indexBufferOffset:ioff instanceCount:instances];
    else
        [enc drawIndexedPrimitives:pt indexCount:count indexType:it indexBuffer:ib indexBufferOffset:ioff];
}

GLFN(void, glDrawArrays, GLenum mode, GLint first, GLsizei count) {
    lock();
    int ok;
    MTLPrimitiveType pt = prim(mode, &ok);
    if (ok && count > 0 && prepare_draw(first, first + count, 0))
        [enc drawPrimitives:pt vertexStart:first vertexCount:count];
    unlock();
}
GLFN(void, glDrawArraysInstancedARB, GLenum mode, GLint first, GLsizei count, GLsizei inst) {
    lock();
    int ok;
    MTLPrimitiveType pt = prim(mode, &ok);
    if (ok && count > 0 && prepare_draw(first, first + count, inst))
        [enc drawPrimitives:pt vertexStart:first vertexCount:count instanceCount:inst];
    unlock();
}
GLFN(void, glDrawBuffer, GLenum b) {
    lock();
    if (S.draw_fbo && fbos[S.draw_fbo]) fbos[S.draw_fbo]->draw_none = b == GL_NONE;
    unlock();
}
GLFN(void, glDrawElementsInstancedARB, GLenum mode, GLsizei count, GLenum type, const void *idx, GLsizei inst) {
    lock();
    // the vertex range is unknown for client arrays here; assume the instanced paths use buffers
    draw_indexed(mode, count, type, idx, 0xffff, inst);
    unlock();
}
GLFN(void, glDrawRangeElements, GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *idx) {
    (void)start;
    lock();
    draw_indexed(mode, count, type, idx, end, 0);
    unlock();
}
GLFN(void, glEnd, void) {
    lock();
    if (S.in_begin == GL_QUADS_ && S.nimm >= 4) {
        ensure_pass(0);
        if (enc) {
            // GL clip space (y up) -> Metal: flip y like the converted shaders do
            float v[4][4];
            int order[4] = {0, 1, 3, 2};                 // quad -> triangle strip
            for (int k = 0; k < 4; k++) {
                float *s = S.imm[order[k]];
                v[k][0] = s[0]; v[k][1] = -s[1]; v[k][2] = s[2]; v[k][3] = s[3];
            }
            apply_dynamic_state();
            id<MTLSamplerState> smp;
            id<MTLTexture> t = unit_texture(S.unit, 0, &smp);
            float params[4] = {S.alpha_ref, S.tex2d_enabled ? 1.0f : 0.0f, (S.alpha_test && S.alpha_func == GL_GREATER) ? 1.0f : 0.0f, 0};
            internal_quad(2, internal_fn[FN_IMM_FS], t, smp, v, params);
        }
    } else if (S.nimm) LOG_ONCE("immediate mode 0x%x with %d vertices", S.in_begin, S.nimm);
    S.in_begin = 0;
    unlock();
}
GLFN(void, glEndQuery, GLenum target) {
    (void)target;
    lock();
    if (S.active_query) queries_ended++;
    S.active_query = 0;
    if (enc) { [enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0]; es.vis_mode = 0; }
    unlock();
}
GLFN(void, glFlushMappedBufferRangeAPPLE, GLenum target, GLintptr off, GLsizeiptr size) { (void)target; (void)off; (void)size; }
GLFN(void, glFramebufferRenderbuffer, GLenum target, GLenum att, GLenum rbt, GLuint r) {
    (void)rbt;
    lock();
    GLuint f = target == GL_READ_FRAMEBUFFER ? S.read_fbo : S.draw_fbo;
    Fbo *fb = f ? fbos[f] : NULL;
    if (fb) {
        Att a = {r ? 2 : 0, r, 0, 0};
        if (att >= GL_COLOR_ATTACHMENT0 && att <= GL_COLOR_ATTACHMENT3) fb->color[att - GL_COLOR_ATTACHMENT0] = a;
        else if (att == GL_DEPTH_ATTACHMENT) fb->depth = a;
        else if (att == GL_STENCIL_ATTACHMENT) fb->stencil = a;
        else if (att == GL_DEPTH_STENCIL_ATTACHMENT) fb->depth = fb->stencil = a;
    }
    unlock();
}
GLFN(void, glFramebufferTexture2D, GLenum target, GLenum att, GLenum textarget, GLuint t, GLint level) {
    lock();
    GLuint f = target == GL_READ_FRAMEBUFFER ? S.read_fbo : S.draw_fbo;
    Fbo *fb = f ? fbos[f] : NULL;
    if (fb) {
        GLenum base;
        int face = face_of(textarget, &base);
        Att a = {t ? 1 : 0, t, level, face};
        if (att >= GL_COLOR_ATTACHMENT0 && att <= GL_COLOR_ATTACHMENT3) fb->color[att - GL_COLOR_ATTACHMENT0] = a;
        else if (att == GL_DEPTH_ATTACHMENT) fb->depth = a;
        else if (att == GL_STENCIL_ATTACHMENT) fb->stencil = a;
        else if (att == GL_DEPTH_STENCIL_ATTACHMENT) fb->depth = fb->stencil = a;
    }
    unlock();
}
static void gen_names(int pool, GLsizei n, GLuint *out) {
    lock();
    for (int k = 0; k < n; k++) out[k] = gen_name(pool);
    unlock();
}
GLFN(void, glGenBuffers, GLsizei n, GLuint *b) {
    gen_names(P_BUF, n, b);
    lock();
    for (int k = 0; k < n; k++) if (b[k] && !bufs[b[k]]) bufs[b[k]] = calloc(1, sizeof(Buf));
    unlock();
}
GLFN(void, glGenFramebuffers, GLsizei n, GLuint *f) {
    gen_names(P_FBO, n, f);
    lock();
    for (int k = 0; k < n; k++) if (f[k] && !fbos[f[k]]) fbos[f[k]] = calloc(1, sizeof(Fbo));
    unlock();
}
GLFN(void, glGenQueries, GLsizei n, GLuint *q) {
    gen_names(P_QUERY, n, q);
    lock();
    for (int k = 0; k < n; k++) if (q[k] && !queries[q[k]]) queries[q[k]] = calloc(1, sizeof(Query));
    unlock();
}
GLFN(void, glGenRenderbuffers, GLsizei n, GLuint *r) {
    gen_names(P_RB, n, r);
    lock();
    for (int k = 0; k < n; k++) if (r[k] && !rbs[r[k]]) rbs[r[k]] = calloc(1, sizeof(Rb));
    unlock();
}
GLFN(void, glGenTextures, GLsizei n, GLuint *t) {
    gen_names(P_TEX, n, t);
    lock();
    for (int k = 0; k < n; k++) if (t[k] && !texs[t[k]]) texs[t[k]] = new_tex(GL_TEXTURE_2D);
    unlock();
}
static GLenum gl_type_of(int kind) {
    switch (kind) {
        case MGL_VEC4: return GL_FLOAT_VEC4;
        case MGL_IVEC4: return GL_INT_VEC4;
        case MGL_BOOL: return GL_BOOL;
        case MGL_SAMPLER2D: return GL_SAMPLER_2D;
        case MGL_SAMPLERCUBE: return GL_SAMPLER_CUBE;
        case MGL_FLOAT: return GL_FLOAT;
        case MGL_VEC2: return GL_FLOAT_VEC2;
        case MGL_VEC3: return GL_FLOAT_VEC3;
        case MGL_INT: return GL_INT;
        case MGL_MAT4: return GL_FLOAT_MAT4;
    }
    return GL_FLOAT_VEC4;
}
GLFN(void, glGetActiveUniform, GLuint p, GLuint idx, GLsizei bufsize, GLsizei *len, GLint *size, GLenum *type, char *name) {
    lock();
    Prog *pr = p < NAMES ? progs[p] : NULL;
    if (pr && idx < (GLuint)pr->nu) {
        MglUniform *u = &pr->u[idx];
        int n = snprintf(name, bufsize, "%s%s", u->name, u->count > 1 ? "[0]" : "");
        if (n >= bufsize) n = bufsize - 1;
        if (len) *len = n;
        if (size) *size = u->count;
        if (type) *type = gl_type_of(u->kind);
    } else if (bufsize > 0) { name[0] = 0; if (len) *len = 0; }
    unlock();
}
GLFN(void, glGetIntegerv, GLenum pname, GLint *v) {
    switch (pname) {
        case GL_MAX_SAMPLES_: *v = 4; break;
        case GL_MAX_TEXTURE_SIZE: *v = 16384; break;
        case GL_MAX_VERTEX_ATTRIBS: *v = 16; break;
        case GL_MAX_TEXTURE_IMAGE_UNITS: *v = 16; break;
        default: LOG_ONCE("glGetIntegerv 0x%x", pname); *v = 0;
    }
}
GLFN(void, glGetProgramiv, GLuint p, GLenum pname, GLint *v) {
    lock();
    Prog *pr = p < NAMES ? progs[p] : NULL;
    switch (pname) {
        case GL_LINK_STATUS: case GL_VALIDATE_STATUS: *v = 1; break;
        case GL_INFO_LOG_LENGTH: *v = 0; break;
        case GL_ACTIVE_UNIFORMS: *v = pr ? pr->nu : 0; break;
        case GL_ACTIVE_UNIFORM_MAX_LENGTH: *v = 68; break;
        case GL_ATTACHED_SHADERS: *v = pr ? (pr->vs != 0) + (pr->fs != 0) : 0; break;
        default: LOG_ONCE("glGetProgramiv 0x%x", pname); *v = 0;
    }
    unlock();
}

static uint64_t query_result(Query *q) {
    uint64_t sum = 0;
    uint64_t *vb = (uint64_t *)[vis[q->frame] contents];
    for (int k = 0; k < q->nslots; k++) sum += vb[q->slot[k]];
    return sum;
}
static int query_done(Query *q) { return q->nslots == 0 || q->serial <= atomic_load(&completed); }
GLFN(void, glGetQueryObjectiv, GLuint id, GLenum pname, GLint *v) {
    lock();
    Query *q = id < NAMES ? queries[id] : NULL;
    if (!q) *v = 0;
    else if (pname == GL_QUERY_RESULT_AVAILABLE) {
        if (!query_done(q) && q->serial == serial && cmd) { submit(0); begin_frame(); }   // as GL, polling flushes
        *v = query_done(q);
    }
    else {
        if (!query_done(q)) {
            double t0 = now_ms();
            if (q->serial == serial) submit(1); else while (!query_done(q)) usleep(50);
            hz.query += now_ms() - t0; hz.nquery++;
        }
        *v = (GLint)query_result(q);
    }
    unlock();
}
GLFN(void, glGetQueryObjectuiv, GLuint id, GLenum pname, GLuint *v) {
    GLint r;
    mgl_glGetQueryObjectiv(id, pname, &r);
    *v = (GLuint)r;
}
GLFN(void, glGetShaderInfoLog, GLuint s, GLsizei bufsize, GLsizei *len, char *log) {
    (void)s;
    if (bufsize > 0) log[0] = 0;
    if (len) *len = 0;
}
GLFN(void, glGetShaderiv, GLuint s, GLenum pname, GLint *v) {
    (void)s;
    switch (pname) {
        case GL_COMPILE_STATUS: *v = 1; break;
        case GL_INFO_LOG_LENGTH: *v = 0; break;
        case GL_SHADER_TYPE: lock(); *v = s < NAMES && shaders[s] ? shaders[s]->type : 0; unlock(); break;
        default: LOG_ONCE("glGetShaderiv 0x%x", pname); *v = 0;
    }
}
GLFN(GLint, glGetUniformLocation, GLuint p, const char *name) {
    lock();
    Prog *pr = p < NAMES ? progs[p] : NULL;
    GLint loc = -1;
    if (pr) {
        char base[64];
        snprintf(base, sizeof base, "%s", name);
        int elem = 0;
        char *br = strchr(base, '[');
        if (br) { elem = atoi(br + 1); *br = 0; }
        for (int k = 0; k < pr->nu; k++)
            if (!strcmp(pr->u[k].name, base) && elem < pr->u[k].count) { loc = k * 1024 + elem; break; }
    }
    unlock();
    return loc;
}
GLFN(void, glLinkProgram, GLuint p) {
    lock();
    Prog *pr = p < NAMES ? progs[p] : NULL;
    Shader *vs = pr && pr->vs < NAMES ? shaders[pr->vs] : NULL, *fs = pr && pr->fs < NAMES ? shaders[pr->fs] : NULL;
    if (pr && vs && fs && vs->src && fs->src) {
        free(pr->src[0]); free(pr->src[1]); free(pr->block[0]); free(pr->block[1]);
        pr->src[0] = strdup(vs->src); pr->src[1] = strdup(fs->src);
        pr->nu = 0;
        for (int st = 0; st < 2; st++) {
            int bo;
            int n = mgl_reflect(pr->src[st], st, pr->u + pr->nu, 128 - pr->nu, &pr->bsize[st], &bo);
            if (st == 1) pr->bias_off = bo;
            if (n < 0) { MGL_LOG("program %u: uniform reflection failed\n", p); n = 0; }
            pr->nsamp[st] = 0;
            for (int k = pr->nu; k < pr->nu + n; k++)
                if (pr->u[k].kind == MGL_SAMPLER2D || pr->u[k].kind == MGL_SAMPLERCUBE) {
                    int b = pr->u[k].binding;
                    pr->skind[st][b] = pr->u[k].kind; pr->unit[st][b] = 0;
                    if (b + 1 > pr->nsamp[st]) pr->nsamp[st] = b + 1;
                }
            pr->nu += n;
            pr->block[st] = calloc(1, pr->bsize[st] + 16);
        }
        // vertex inputs: declared attributes and their locations (bound ones, then the rest in order)
        MglAttrib va[16];
        int nva = resolve_attrs(pr->src[0], lookup_prog, pr, va);
        pr->attr_used = 0;
        for (int k = 0; k < nva; k++) if (va[k].location < 16) pr->attr_used |= 1u << va[k].location;
        if (pr->warm) { unlock(); dispatch_group_wait(pr->warm, DISPATCH_TIME_FOREVER); lock(); }
        pr->gen++;
        [pr->fn[0] release]; [pr->fn[1] release];
        pr->fn[0] = pr->fn[1] = nil;
        pr->name = p;
        prog_link_stages(pr, p);
    }
    unlock();
}
GLFN(void *, glMapBuffer, GLenum target, GLenum access) {
    (void)access;
    lock();
    Buf *b = buf_bound(target);
    void *r = NULL;
    if (b) {
        if (!b->mb) buf_alloc(b, b->size ? b->size : 16, NULL, 0);
        else if (b->used && b->used >= atomic_load(&completed)) buf_alloc(b, b->size, NULL, 1);   // GPU may still read it
        r = [b->mb contents];
        b->map = r;
    }
    unlock();
    return r;
}
GLFN(void, glPixelStorei, GLenum pname, GLint v) {
    lock();
    if (pname == GL_UNPACK_ALIGNMENT) S.unpack_align = v > 0 ? v : 4;
    else LOG_ONCE("glPixelStorei 0x%x", pname);
    unlock();
}
GLFN(void, glPolygonMode, GLenum face, GLenum mode) { (void)face; lock(); S.poly_mode = mode; unlock(); }
GLFN(void, glPolygonOffset, GLfloat factor, GLfloat units) { lock(); S.offset_factor = factor; S.offset_units = units; unlock(); }
GLFN(void, glReadBuffer, GLenum b) {
    lock();
    if (S.read_fbo && fbos[S.read_fbo]) fbos[S.read_fbo]->read_none = b == GL_NONE;
    unlock();
}
GLFN(void, glReadPixels, GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type, void *out) {
    lock();
    int lv, sl;
    id<MTLTexture> src = read_color(&lv, &sl);
    pc_flush(src);
    if (src && cmd) submit(1);
    if (src) {
        // render targets are private when they are the backbuffer: copy through a shared buffer
        size_t row = (size_t)w * 4;
        id<MTLBuffer> tmp = [dev newBufferWithLength:row * h options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> c = [queue commandBuffer];
        id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
        [b copyFromTexture:src sourceSlice:sl sourceLevel:lv sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(w, h, 1)
                  toBuffer:tmp destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
        [b endEncoding];
        [c commit];
        [c waitUntilCompleted];
        const uint8_t *s = [tmp contents];
        if (src.pixelFormat == MTLPixelFormatBGRA8Unorm && type == GL_UNSIGNED_BYTE) {
            for (int r = 0; r < h; r++)
                for (int k = 0; k < w; k++) {
                    const uint8_t *px = s + r * row + 4 * k;
                    uint8_t *d = (uint8_t *)out + ((size_t)r * w + k) * 4;
                    if (format == GL_RGBA) { d[0] = px[2]; d[1] = px[1]; d[2] = px[0]; d[3] = px[3]; }
                    else memcpy(d, px, 4);
                }
        } else LOG_ONCE("glReadPixels from format %lu", (unsigned long)src.pixelFormat);
        [tmp release];
    }
    unlock();
}
GLFN(void, glRenderbufferStorage, GLenum target, GLenum ifmt, GLsizei w, GLsizei h) {
    (void)target;
    lock();
    Rb *r = S.rb ? rbs[S.rb] : NULL;
    const Fmt *f = find_fmt(ifmt);
    if (r && f) {
        if (r->mt) [r->mt release];
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f->pf width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        r->mt = [dev newTextureWithDescriptor:d];
        r->ifmt = ifmt; r->w = w; r->h = h;
    } else if (!f) LOG_ONCE("renderbuffer format 0x%x", ifmt);
    unlock();
}
GLFN(void, glRenderbufferStorageMultisample, GLenum target, GLsizei samples, GLenum ifmt, GLsizei w, GLsizei h) {
    if (samples > 1) LOG_ONCE("multisampled renderbuffers are single-sampled");
    mgl_glRenderbufferStorage(target, ifmt, w, h);
}
GLFN(void, glScissor, GLint x, GLint y, GLsizei w, GLsizei h) {
    lock(); S.scissor[0] = x; S.scissor[1] = y; S.scissor[2] = w; S.scissor[3] = h; unlock();
}
GLFN(void, glShaderSource, GLuint s, GLsizei count, const char *const *str, const GLint *len) {
    lock();
    Shader *sh = s < NAMES ? shaders[s] : NULL;
    if (sh) {
        size_t total = 0;
        for (int k = 0; k < count; k++) total += len && len[k] >= 0 ? (size_t)len[k] : strlen(str[k]);
        free(sh->src);
        sh->src = malloc(total + 1);
        char *p = sh->src;
        for (int k = 0; k < count; k++) {
            size_t n = len && len[k] >= 0 ? (size_t)len[k] : strlen(str[k]);
            memcpy(p, str[k], n); p += n;
        }
        *p = 0;
        stage_precompile(sh);
    }
    unlock();
}
static void stencil_func(int face, GLenum f, GLint ref, GLuint mask) { S.sf[face].func = f; S.sf[face].ref = ref; S.sf[face].mask = mask; }
static void stencil_op(int face, GLenum a, GLenum b, GLenum c) { S.sf[face].fail = a; S.sf[face].zfail = b; S.sf[face].zpass = c; }
GLFN(void, glStencilFunc, GLenum f, GLint ref, GLuint mask) { lock(); stencil_func(0, f, ref, mask); stencil_func(1, f, ref, mask); unlock(); }
GLFN(void, glStencilFuncSeparate, GLenum face, GLenum f, GLint ref, GLuint mask) {
    lock();
    if (face != GL_BACK) stencil_func(0, f, ref, mask);
    if (face != GL_FRONT) stencil_func(1, f, ref, mask);
    unlock();
}
GLFN(void, glStencilMask, GLuint m) { lock(); S.stencil_wmask = m; unlock(); }
GLFN(void, glStencilOp, GLenum a, GLenum b, GLenum c) { lock(); stencil_op(0, a, b, c); stencil_op(1, a, b, c); unlock(); }
GLFN(void, glStencilOpSeparate, GLenum face, GLenum a, GLenum b, GLenum c) {
    lock();
    if (face != GL_BACK) stencil_op(0, a, b, c);
    if (face != GL_FRONT) stencil_op(1, a, b, c);
    unlock();
}
GLFN(void, glTexCoord2f, GLfloat s, GLfloat t) { lock(); S.tc[0] = s; S.tc[1] = t; unlock(); }
GLFN(void, glTexEnvf, GLenum target, GLenum pname, GLfloat v) {
    lock();
    if (pname == GL_TEXTURE_LOD_BIAS_) S.lod_bias[S.unit] = v;
    else LOG_ONCE("glTexEnvf 0x%x 0x%x", target, pname);
    unlock();
}
GLFN(void, glTexImage2D, GLenum target, GLint level, GLint ifmt, GLsizei w, GLsizei h, GLint border, GLenum format,
     GLenum type, const void *data) {
    (void)border;
    lock();
    const void *p = (data || S.unpack_buf) ? unpack_ptr((uint64_t)data) : NULL;
    if (ifmt == GL_RGBA) ifmt = GL_RGBA8;
    tex_image(target, level, ifmt, w, h, p, 0, format, type, 0);
    unlock();
}
GLFN(void, glTexParameteri, GLenum target, GLenum pname, GLint v) {
    lock();
    GLenum base;
    face_of(target, &base);
    Tex *t = tex_of(bound_tex_name(base));
    if (t) {
        switch (pname) {
            case GL_TEXTURE_MIN_FILTER: t->min_f = v; break;
            case GL_TEXTURE_MAG_FILTER: t->mag_f = v; break;
            case GL_TEXTURE_WRAP_S: t->wrap_s = v; break;
            case GL_TEXTURE_WRAP_T: t->wrap_t = v; break;
            case GL_TEXTURE_WRAP_R: break;
            case GL_TEXTURE_BASE_LEVEL: t->base_level = v; break;
            case GL_TEXTURE_MAX_LEVEL: t->max_level = v; break;
            case GL_MAX_ANISOTROPY_: t->aniso = v; break;
            default: LOG_ONCE("glTexParameteri 0x%x", pname);
        }
        if (t->samp) { [t->samp release]; t->samp = nil; }
    }
    unlock();
}
GLFN(void, glTexSubImage2D, GLenum target, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type,
     const void *data) {
    lock();
    GLenum base;
    int face = face_of(target, &base);
    Tex *t = tex_of(bound_tex_name(base));
    const void *p = (data || S.unpack_buf) ? unpack_ptr((uint64_t)data) : NULL;
    if (t && p) tex_upload(t, level, face, x, y, w, h, p, 0, format, type, 0);
    unlock();
}

static Prog *cur_prog(void) { return S.prog && S.prog < NAMES ? progs[S.prog] : NULL; }
static MglUniform *uniform_at(Prog *p, GLint loc, int *elem) {
    if (!p || loc < 0) return NULL;
    int idx = loc / 1024;
    *elem = loc % 1024;
    return idx < p->nu ? &p->u[idx] : NULL;
}
GLFN(void, glUniform1i, GLint loc, GLint v) {
    lock();
    Prog *p = cur_prog();
    int e;
    MglUniform *u = uniform_at(p, loc, &e);
    if (u) {
        if (u->kind == MGL_SAMPLER2D || u->kind == MGL_SAMPLERCUBE) p->unit[u->stage][u->binding] = v;
        else if (u->offset >= 0 && e < u->count) memcpy(p->block[u->stage] + u->offset + e * u->stride, &v, 4);
    }
    unlock();
}
GLFN(void, glUniform1iv, GLint loc, GLsizei n, const GLint *v) {
    lock();
    Prog *p = cur_prog();
    int e;
    MglUniform *u = uniform_at(p, loc, &e);
    if (u && u->offset >= 0)
        for (int k = 0; k < n && e + k < u->count; k++) memcpy(p->block[u->stage] + u->offset + (e + k) * u->stride, &v[k], 4);
    else if (u) for (int k = 0; k < n && u->binding + k < 16; k++) p->unit[u->stage][u->binding + k] = v[k];
    unlock();
}
GLFN(void, glUniform4fv, GLint loc, GLsizei n, const GLfloat *v) {
    lock();
    Prog *p = cur_prog();
    int e;
    MglUniform *u = uniform_at(p, loc, &e);
    if (u && u->offset >= 0) {
        if (e + n > u->count) n = u->count - e;
        if (n > 0) {
            if (u->stride == 16) memcpy(p->block[u->stage] + u->offset + e * 16, v, (size_t)n * 16);
            else for (int k = 0; k < n; k++) memcpy(p->block[u->stage] + u->offset + (e + k) * u->stride, v + 4 * k, 16);
        }
    }
    unlock();
}
GLFN(GLboolean, glUnmapBuffer, GLenum target) {
    lock();
    Buf *b = buf_bound(target);
    if (b) b->map = NULL;
    unlock();
    return GL_TRUE;
}
GLFN(void, glUseProgram, GLuint p) { lock(); S.prog = p; unlock(); }
GLFN(void, glVertex2f, GLfloat x, GLfloat y) {
    lock();
    if (S.nimm < 64) { float *v = S.imm[S.nimm++]; v[0] = x; v[1] = y; v[2] = S.tc[0]; v[3] = S.tc[1]; }
    unlock();
}
GLFN(void, glVertexAttribDivisorARB, GLuint i, GLuint d) { lock(); if (i < 16) S.attr[i].divisor = d; unlock(); }
GLFN(void, glVertexAttribPointer, GLuint i, GLint size, GLenum type, GLboolean norm, GLsizei stride, const void *ptr) {
    lock();
    if (i < 16) {
        Attrib *a = &S.attr[i];
        a->size = size; a->type = type; a->normalized = norm; a->stride = stride;
        a->buffer = S.array_buf; a->ptr = (uint64_t)ptr;
    }
    unlock();
}
GLFN(void, glViewport, GLint x, GLint y, GLsizei w, GLsizei h) {
    lock(); S.viewport[0] = x; S.viewport[1] = y; S.viewport[2] = w; S.viewport[3] = h; unlock();
}

// ---------- screen ----------
// RT_SCREEN=<index or part of a name>: the display the game runs on (default: the main display). The
// game asks +[NSScreen mainScreen] and CGMainDisplayID (see send in objc.m and the thunk below) and centres
// its window before making it fullscreen (mgl_center_window), so all three point at the chosen screen.
void *rt_screen(void) {
    static NSScreen *chosen;
    static int init;
    if (!init) {
        init = 1;
        const char *want = getenv("RT_SCREEN");
        if (want) {
            NSArray<NSScreen *> *all = NSScreen.screens;
            char *end;
            long n = strtol(want, &end, 10);
            if (!*end && n >= 0 && n < (long)all.count) chosen = all[n];
            else
                for (NSScreen *x in all)
                    if ([x.localizedName.lowercaseString containsString:[NSString stringWithUTF8String:want].lowercaseString]) { chosen = x; break; }
            if (chosen) { [chosen retain]; MGL_LOG("screen: %s\n", chosen.localizedName.UTF8String); }
            else MGL_LOG("RT_SCREEN=%s: no such screen\n", want);
        }
    }
    return chosen ? chosen : NSScreen.mainScreen;
}
int rt_screen_chosen(void) { rt_screen(); return getenv("RT_SCREEN") != NULL; }
void I__CGMainDisplayID(CPU *c) {
    NSScreen *s = (NSScreen *)rt_screen();
    C.rax = s ? [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : CGMainDisplayID();
    C.rsp += 8;
}
static void center_on_screen(void *w_) {
    NSWindow *w = (NSWindow *)w_;
    NSRect v = ((NSScreen *)rt_screen()).visibleFrame, f = w.frame;
    [w setFrameOrigin:NSMakePoint(v.origin.x + (v.size.width - f.size.width) / 2, v.origin.y + (v.size.height - f.size.height) / 2)];
}
void mgl_center_window(void *w) { rt_main_sync(center_on_screen, w); }

// ---------- context (NSOpenGLContext replacements) ----------
static int swap_interval = 1;
// RT_TEST_SETRES=<seconds>:<W>x<H>[,...]: change the fullscreen resolution as the options menu does (the
// setting, then a resize of the viewport), to test resolution changes without the menu
#define GSYSTEMSETTINGS 0x101890ee0ull   // FSystemSettings: bFullscreen +0x4e8, ResFullscreenX/Y +0x4f0
static void test_setres(NSView *view) {
    const char *spec = getenv("RT_TEST_SETRES");
    if (!spec) return;
    [view retain];
    for (const char *p = spec; p && *p; p = strchr(p, ',') ? strchr(p, ',') + 1 : NULL) {
        double t; int w, h;
        if (sscanf(p, "%lf:%dx%d", &t, &w, &h) != 3) break;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * 1e9)), dispatch_get_main_queue(), ^{
            MGL_LOG("test: fullscreen resolution %dx%d\n", w, h);
            wr32(G(GSYSTEMSETTINGS + 0x4f0), w);
            wr32(G(GSYSTEMSETTINGS + 0x4f4), h);
            [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResizeNotification object:view.window];
        });
    }
}
static void attach_layer(void *view_) {
    NSView *view = (NSView *)view_;
    [view setWantsLayer:YES];
    CAMetalLayer *l = [CAMetalLayer layer];
    l.device = dev;
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.framebufferOnly = YES;
    // the window's real backing scale: 2 on Retina when the app is NSHighResolutionCapable, else 1
    CGFloat scale = view.window ? view.window.backingScaleFactor : ((NSScreen *)rt_screen()).backingScaleFactor;
    if (getenv("RT_METAL_SCALE")) scale = atof(getenv("RT_METAL_SCALE"));
    l.contentsScale = scale;
    [view setLayer:l];
    l.drawableSize = CGSizeMake(view.bounds.size.width * scale, view.bounds.size.height * scale);
    MGL_LOG("drawable %.0fx%.0f (view %.0fx%.0f points, scale %.1f)\n", l.drawableSize.width, l.drawableSize.height,
            view.bounds.size.width, view.bounds.size.height, scale);
    l.maximumDrawableCount = 3;
    l.displaySyncEnabled = swap_interval != 0 && !getenv("RT_NOVSYNC");
    layer = [l retain];
    test_setres(view);
}

void mgl_set_view(void *view) {
    lock();
    if (!layer) {
        unlock();
        rt_main_sync(attach_layer, view);
        lock();
    }
    unlock();
}

void mgl_set_swap_interval(int n) {
    lock();
    swap_interval = n;
    if (layer) layer.displaySyncEnabled = n != 0;
    unlock();
}

// RT_METAL_SNAP=<frame>[,<frame>...] with RT_METAL_SNAP_DIR: save the default framebuffer of those
// presented frames as raw BGRA (<dir>/frame<N>.bgra, preceded by a "W H\n" header line)
static void snapshot(void) {
    static long frame;
    static const char *list = (const char *)-1;
    if (list == (const char *)-1) list = getenv("RT_METAL_SNAP");
    frame++;
    if (!list || !back_color) return;
    char key[32];
    snprintf(key, sizeof key, ",%ld,", frame);
    char buf[512];
    snprintf(buf, sizeof buf, ",%s,", list);
    if (!strstr(buf, key)) return;
    size_t row = (size_t)back_w * 4;
    id<MTLBuffer> tmp = [dev newBufferWithLength:row * back_h options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
    [b copyFromTexture:back_color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(back_w, back_h, 1)
              toBuffer:tmp destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * back_h];
    [b endEncoding];
    id<MTLCommandBuffer> c = cmd;
    cmd = nil;
    [c commit];
    [c waitUntilCompleted];
    [c release];
    serial++;
    frame_index = (frame_index + 1) % NBUF;
    queries_ended = 0;
    const char *dir = getenv("RT_METAL_SNAP_DIR") ? getenv("RT_METAL_SNAP_DIR") : "/tmp";
    char path[600];
    snprintf(path, sizeof path, "%s/frame%ld.bgra", dir, frame);
    FILE *f = fopen(path, "wb");
    if (f) { fprintf(f, "%d %d\n", back_w, back_h); fwrite([tmp contents], 1, row * back_h, f); fclose(f); }
    MGL_LOG("saved %s\n", path);
    [tmp release];
    begin_frame();
}

// ---------- Retina render scale and upscaling ----------
// With a Retina screen the game works in units of points x render scale (geometry is converted in send,
// objc.m, and CGEventGetLocation). In fullscreen the scale is the game's chosen resolution across the
// screen's width in points, so it renders at that resolution and its own final stretch to the display
// is 1:1; windowed it is 1 (a 1280x720 window is 1280x720 points). The frame is then upscaled to the
// native drawable with MetalFX spatial scaling (RT_METAL_UPSCALE=bilinear for a plain stretch).
static int retina_modes(void);
int mgl_game_fullscreen(void);
static double render_scale(void) {
    if (!retina_modes()) return 0;
    static double screen_w, backing;
    if (!screen_w) { NSScreen *sc = (NSScreen *)rt_screen(); backing = sc.backingScaleFactor; screen_w = sc.frame.size.width; }
    double rs = 1;
    int w = (int)rd32(G(GSYSTEMSETTINGS + 0x4f0));
    if (mgl_game_fullscreen() && w > 0) rs = w / screen_w;
    if (rs < 0.25) rs = 0.25;
    if (rs > backing) rs = backing;
    static double logged;
    if (rs != logged) {
        logged = rs;
        MGL_LOG("render scale %.3f (fullscreen %d, ResFullscreenX %d, ResX %d)\n", rs, rd32(G(GSYSTEMSETTINGS + 0x4e8)), w,
                rd32(G(GSYSTEMSETTINGS + 0x4e0)));
    }
    return rs;
}
static id<MTLFXSpatialScaler> scaler;
static id<MTLTexture> upscaled;
static id<MTLTexture> upscale(id<MTLTexture> in, int ow, int oh, id<MTLSamplerState> *smp) {
    static int bilinear = -1;
    if (bilinear < 0) bilinear = getenv("RT_METAL_UPSCALE") && !strcmp(getenv("RT_METAL_UPSCALE"), "bilinear");
    if (bilinear || ![MTLFXSpatialScalerDescriptor supportsDevice:dev]) { *smp = samp_linear; return in; }
    if (!scaler || scaler.inputWidth != in.width || scaler.inputHeight != in.height || scaler.outputWidth != (NSUInteger)ow ||
        scaler.outputHeight != (NSUInteger)oh) {
        [scaler release]; [upscaled release];
        MTLFXSpatialScalerDescriptor *sd = [[MTLFXSpatialScalerDescriptor alloc] init];
        sd.inputWidth = in.width; sd.inputHeight = in.height;
        sd.outputWidth = ow; sd.outputHeight = oh;
        sd.colorTextureFormat = in.pixelFormat;
        sd.outputTextureFormat = in.pixelFormat;
        sd.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        scaler = [sd newSpatialScalerWithDevice:dev];
        [sd release];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:in.pixelFormat width:ow height:oh mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = scaler.outputTextureUsage | MTLTextureUsageShaderRead;
        upscaled = [dev newTextureWithDescriptor:td];
        MGL_LOG("MetalFX upscaling %lux%lu -> %dx%d\n", (unsigned long)in.width, (unsigned long)in.height, ow, oh);
    }
    scaler.colorTexture = in;
    scaler.outputTexture = upscaled;
    [scaler encodeToCommandBuffer:cmd];
    *smp = samp_nearest;
    return upscaled;
}

// flushBuffer: draw the default framebuffer onto the drawable (flipping it upright) and present
void mgl_present(void) {
    lock();
    if (!layer) { unlock(); return; }
    begin_frame();
    end_pass();
    ensure_backbuffer();
    pc_flush(back_color);
    snapshot();
    {
        static long want = -2;
        if (want == -2) want = getenv("RT_METAL_PASSLOG") ? atol(getenv("RT_METAL_PASSLOG")) : -1;
        PLOG("present t%d\n", tid(back_color));
        if (passlog_on) MGL_LOG("pass log done\n");
        present_count++;
        passlog_on = present_count == want;
    }
    double td = now_ms();
    id<CAMetalDrawable> d = [layer nextDrawable];
    hz.drawable += now_ms() - td;
    if (d && back_color) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        enc = [[cmd renderCommandEncoderWithDescriptor:rp] retain];
        memset(&cur_t, 0, sizeof cur_t);
        cur_t.color[0] = d.texture; cur_t.ncolor = 1;
        memset(&es, 0, sizeof es);
        // backbuffer row 0 is the bottom of the image: map it to the bottom of the drawable
        float v[4][4] = {{-1, 1, 0, 1}, {1, 1, 1, 1}, {-1, -1, 0, 0}, {1, -1, 1, 0}};
        id<MTLTexture> src = back_color;
        id<MTLSamplerState> smp = samp_nearest;
        if ((int)d.texture.width != back_w || (int)d.texture.height != back_h) {
            end_pass();                             // upscale first (outside the drawable's pass)
            src = upscale(back_color, (int)d.texture.width, (int)d.texture.height, &smp);
            enc = [[cmd renderCommandEncoderWithDescriptor:rp] retain];
            memset(&es, 0, sizeof es);
        }
        internal_quad(3, internal_fn[FN_COPY_FS], src, smp, v, NULL);
        end_pass();
        [cmd presentDrawable:d];
    }
    submit(0);
    if (pool) { objc_autoreleasePoolPop(pool); pool = NULL; }
    {
        static double last, limit = -1;
        if (limit < 0) limit = getenv("RT_METAL_HITCH") ? atof(getenv("RT_METAL_HITCH")) : getenv("RT_FPS") ? 25 : 0;
        double t = now_ms();
        if (limit > 0 && last && t - last > limit)
            MGL_LOG("slow frame %.1f ms: %d new pipelines %.1f ms, %d shader waits %.1f ms, %d query waits %.1f ms, "
                    "drawable %.1f ms, %d buffer allocs %.1f ms\n", t - last, hz.npipe, hz.pipe, hz.nprogwait, hz.progwait,
                    hz.nquery, hz.query, hz.drawable, hz.nalloc, hz.alloc);
        last = t;
        memset(&hz, 0, sizeof hz);
    }
    // keep the layer's drawable size in step with the view
    CGSize sz = layer.bounds.size;
    sz.width *= layer.contentsScale; sz.height *= layer.contentsScale;
    if (sz.width > 0 && (sz.width != layer.drawableSize.width || sz.height != layer.drawableSize.height)) {
        layer.drawableSize = sz;
        MGL_LOG("drawable resized to %.0fx%.0f\n", sz.width, sz.height);
    }
    unlock();
}

void mgl_init(void) {
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&L, &a);
    dev = MTLCreateSystemDefaultDevice();
    queue = [dev newCommandQueue];
    inflight = dispatch_semaphore_create(NBUF);
    for (int k = 0; k < NBUF; k++) {
        ring[k] = [dev newBufferWithLength:RING_SIZE options:MTLResourceStorageModeShared];
        vis[k] = [dev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared];
    }
    float za[4] = {0, 0, 0, 1};
    zero_attr = [dev newBufferWithBytes:za length:sizeof za options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    dummy2d = [dev newTextureWithDescriptor:d];
    uint8_t black[4] = {0, 0, 0, 255};
    [dummy2d replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:black bytesPerRow:4];
    d = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared;
    dummycube = [dev newTextureWithDescriptor:d];
    for (int f = 0; f < 6; f++)
        [dummycube replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:f withBytes:black bytesPerRow:4 bytesPerImage:4];
    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    dummy_samp = [dev newSamplerStateWithDescriptor:sd];
    [sd release];
    mgl_shader_init();
    compile_opts = [[MTLCompileOptions alloc] init];
    compile_opts.preserveInvariance = YES;
    compile_q = dispatch_queue_create("mgl.compile", DISPATCH_QUEUE_CONCURRENT);
    compile_slots = dispatch_semaphore_create(12);
    pipe_records_load();
    lib_cache_init();
    pipe_prewarm();
    init_internal();
    // GL defaults
    S.depth_func = GL_LESS; S.depth_mask = 1; S.depth_far = 1; S.clear_depth = 1;
    S.cull_face = GL_BACK;
    S.color_mask = 15;
    S.bsrc_rgb = S.bsrc_a = GL_ONE; S.bdst_rgb = S.bdst_a = GL_ZERO;
    S.beq_rgb = S.beq_a = GL_FUNC_ADD;
    for (int f = 0; f < 2; f++) { S.sf[f].func = GL_ALWAYS; S.sf[f].mask = ~0u; S.sf[f].fail = S.sf[f].zfail = S.sf[f].zpass = GL_KEEP; }
    S.stencil_wmask = ~0u;
    S.unpack_align = 4;
    S.alpha_func = GL_ALWAYS;
    S.poly_mode = GL_FILL;
    MGL_LOG("Metal renderer on %s\n", dev.name.UTF8String);
}

// ---------- Retina output ----------
// With a Retina window (NSHighResolutionCapable) under Metal, the game may render at the display's
// pixel resolution: report display modes in pixels so it accepts e.g. ResX=5120 on a 2560-point
// screen. (It validates its resolution against this list; it never switches display modes: fullscreen
// is a native fullscreen window, and the chosen resolution sets the render scale.)
static int retina_modes(void) {
    static int on = -1;
    if (on < 0) {
        id hidpi = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSHighResolutionCapable"];
        on = rt_metal && [hidpi boolValue] && ((NSScreen *)rt_screen()).backingScaleFactor > 1.0;
        if (on) MGL_LOG("Retina: display modes reported in pixels\n");
    }
    return on;
}
// The game's resolution list is the display's modes; on Retina the current (HiDPI) mode is added and
// reported in pixels, so the native resolution can be chosen too
void I__CGDisplayCopyAllDisplayModes(CPU *c) {
    CGDirectDisplayID d = (CGDirectDisplayID)C.rdi;
    CFArrayRef all = CGDisplayCopyAllDisplayModes(d, (CFDictionaryRef)C.rsi);
    if (all && retina_modes()) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
        int have = 0;
        for (CFIndex k = 0; k < CFArrayGetCount(all); k++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, k);
            if (CGDisplayModeGetWidth(m) == CGDisplayModeGetPixelWidth(cur) && CGDisplayModeGetHeight(m) == CGDisplayModeGetPixelHeight(cur)) have = 1;
        }
        if (cur && !have) {
            CFMutableArrayRef more = CFArrayCreateMutableCopy(NULL, 0, all);
            CFArrayAppendValue(more, cur);
            CFRelease(all);
            all = more;
        }
        if (cur) CGDisplayModeRelease(cur);
    }
    C.rax = (uint64_t)all;
    C.rsp += 8;
}
void I__CGDisplayModeGetWidth(CPU *c) {
    CGDisplayModeRef m = (CGDisplayModeRef)C.rdi;
    C.rax = retina_modes() ? CGDisplayModeGetPixelWidth(m) : CGDisplayModeGetWidth(m);
    C.rsp += 8;
}
void I__CGDisplayModeGetHeight(CPU *c) {
    CGDisplayModeRef m = (CGDisplayModeRef)C.rdi;
    C.rax = retina_modes() ? CGDisplayModeGetPixelHeight(m) : CGDisplayModeGetHeight(m);
    C.rsp += 8;
}

// The game pushes and pops its own NSAutoreleasePools; popping one beneath the frame's pool pops that
// too, and popping the frame's pool afterwards is fatal. So the frame's pool is ended whenever the game
// is about to push or pop one on the same thread (everything kept across a frame is retained).
void mgl_pool_yield(void) {
    if (pool && pthread_equal(pool_thread, pthread_self())) { objc_autoreleasePoolPop(pool); pool = NULL; }
}

// whether the game is in (or entering) fullscreen mode
int mgl_game_fullscreen(void) { return rd32(G(GSYSTEMSETTINGS + 0x4e8)) != 0; }

// the factor by which the game's view is reported in pixels rather than points (1: not Retina)
double mgl_view_scale(void) {
    double rs = render_scale();
    return rs > 0 ? rs : 1.0;
}
