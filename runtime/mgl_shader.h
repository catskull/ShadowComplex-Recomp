// Metal renderer shader conversion (mgl_shader.cpp)
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

enum { MGL_VERTEX = 0, MGL_FRAGMENT = 1 };
enum { MGL_VEC4, MGL_IVEC4, MGL_BOOL, MGL_SAMPLER2D, MGL_SAMPLERCUBE, MGL_FLOAT, MGL_VEC2, MGL_VEC3, MGL_INT, MGL_MAT4 };

typedef struct {
    char name[64];
    int stage, kind;
    int count;          // array length (1 for scalars)
    int offset, stride; // byte offset of element 0 and array stride in the stage's uniform block (-1 for samplers)
    int binding;        // samplers: index of the sampler within its stage (Metal texture/sampler slot)
} MglUniform;

typedef struct { char name[64]; int location; } MglAttrib;

void mgl_shader_init(void);          // once, before converting from several threads
// Lays out the stage's uniforms; returns the count (or -1), the block size in bytes and, for fragment
// shaders that sample textures, the offset of the 16 per-sampler LOD bias floats (else -1).
int mgl_reflect(const char *src, int stage, MglUniform *out, int max, int *block_size, int *bias_offset);
// GLSL 1.20 -> MSL; returns a malloc'd string or NULL with a message in err. glsl450 (optional)
// receives the intermediate source.
char *mgl_to_msl(const char *src, int stage, const MglAttrib *attrs, int nattrs, char **glsl450, char *err, unsigned long errlen);

#ifdef __cplusplus
}
#endif
