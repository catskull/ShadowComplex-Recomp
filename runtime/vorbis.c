// libvorbisfile subset (ov_*) on stb_vorbis. The bundled libvorbis is x86-only, and the game
// decodes Vorbis sound data embedded in its packages through these calls.
#include "rt.h"
#include <stdio.h>
#include <stdlib.h>
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#undef C
#include "../third_party/stb_vorbis.c"
#undef C
#define C (*c)              /* stb_vorbis reuses the name */

#define RET() (C.rsp += 8)
#define OV_MAGIC 0x4F565342u          // stored after our pointer inside the guest's OggVorbis_File
#define OV_EREAD (-128)
#define OV_ENOTVORBIS (-132)

void *rt_guest_callback(uint64_t p, const char *sig);

typedef struct {   // vorbis_info, LP64 layout as the guest expects it
    int32_t version, channels;
    int64_t rate, bitrate_upper, bitrate_nominal, bitrate_lower, bitrate_window;
    uint64_t codec_setup;
} GuestVorbisInfo;

typedef struct {
    stb_vorbis *v;
    uint8_t *data;
    GuestVorbisInfo info;
    int (*close)(void *);
    void *datasource;
} OV;

static OV *ov_of(uint64_t vf) { return rd32(vf + 8) == OV_MAGIC ? (OV *)rd64(vf) : 0; }

// int ov_open_callbacks(void *datasource, OggVorbis_File *vf, const char *initial, long ibytes,
//                       ov_callbacks callbacks)   -- the 32-byte callbacks struct is on the stack
void I__ov_open_callbacks(CPU *c) {
    void *ds = (void *)C.rdi;
    uint64_t vf = C.rsi;
    const uint8_t *initial = (const uint8_t *)C.rdx;
    long ibytes = (long)C.rcx;
    size_t (*rd)(void *, size_t, size_t, void *) = rt_guest_callback(rd64(C.rsp + 8), "Q^vQQ^v");
    int (*cl)(void *) = rt_guest_callback(rd64(C.rsp + 24), "i^v");
    size_t cap = 1 << 16, n = 0;
    uint8_t *buf = malloc(cap);
    if (ibytes > 0) { memcpy(buf, initial, ibytes); n = ibytes; }
    for (;;) {
        if (n + 65536 > cap) buf = realloc(buf, cap *= 2);
        size_t got = rd(buf + n, 1, 65536, ds);
        if (!got) break;
        n += got;
    }
    int err = 0;
    stb_vorbis *v = stb_vorbis_open_memory(buf, (int)n, &err, 0);
    if (!v) { free(buf); C.rax = (uint64_t)(int64_t)OV_ENOTVORBIS; RET(); return; }
    OV *o = calloc(1, sizeof *o);
    stb_vorbis_info i = stb_vorbis_get_info(v);
    o->v = v; o->data = buf; o->close = cl; o->datasource = ds;
    o->info.version = 0; o->info.channels = i.channels; o->info.rate = i.sample_rate;
    o->info.bitrate_nominal = 0;
    memset((void *)vf, 0, 16);
    wr64(vf, (uint64_t)o); wr32(vf + 8, OV_MAGIC);
    C.rax = 0;
    RET();
}

void I__ov_info(CPU *c) { OV *o = ov_of(C.rdi); C.rax = o ? (uint64_t)&o->info : 0; RET(); }

// long ov_read(OggVorbis_File *vf, char *buffer, int length, int bigendianp, int word, int sgned, int *bitstream)
void I__ov_read(CPU *c) {
    OV *o = ov_of(C.rdi);
    if (!o) { C.rax = (uint64_t)(int64_t)OV_EREAD; RET(); return; }
    int ch = o->info.channels;
    int shorts = (int)(uint32_t)C.rdx / 2;
    int frames = stb_vorbis_get_samples_short_interleaved(o->v, ch, (short *)C.rsi, shorts - shorts % ch);
    if (rd64(C.rsp + 8)) wr32(rd64(C.rsp + 8), 0);   // *bitstream = 0 (7th argument is on the stack)
    C.rax = (uint64_t)(int64_t)(frames * ch * 2);
    RET();
}

void I__ov_pcm_total(CPU *c) { OV *o = ov_of(C.rdi); C.rax = o ? stb_vorbis_stream_length_in_samples(o->v) : (uint64_t)-1; RET(); }
void I__ov_time_total(CPU *c) { OV *o = ov_of(C.rdi); C.xmm[0].d[0] = o ? stb_vorbis_stream_length_in_seconds(o->v) : -1; RET(); }
void I__ov_pcm_seek_page(CPU *c) {
    OV *o = ov_of(C.rdi);
    C.rax = o && stb_vorbis_seek(o->v, (unsigned)C.rsi) ? 0 : (uint64_t)(int64_t)OV_EREAD;
    RET();
}
void I__ov_clear(CPU *c) {
    OV *o = ov_of(C.rdi);
    if (o) {
        stb_vorbis_close(o->v);
        free(o->data);
        if (o->close) o->close(o->datasource);
        free(o);
        memset((void *)C.rdi, 0, 16);
    }
    C.rax = 0;
    RET();
}
