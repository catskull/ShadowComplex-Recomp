// Metal renderer: the game's GLSL 1.20 shaders -> MSL (see tools/glsl2msl.py for the prototype).
//
// mgl_reflect() parses a shader's uniform declarations and lays them out as one std140 block per
// stage, so uniform offsets are known at glLinkProgram time without compiling anything.
// mgl_to_msl() rewrites the source to GLSL 4.50 with that block, fixed sampler bindings and the
// program's attribute locations, then runs glslang (-> SPIR-V) and SPIRV-Cross (-> MSL 2.1, with
// the vertex Y flip and [-w,w] -> [0,w] depth fixup).
#include <glslang/Include/glslang_c_interface.h>
#include <glslang/Public/resource_limits_c.h>
#include <spirv_cross/spirv_cross_c.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include "mgl_shader.h"

static bool starts(const std::string &s, size_t at, const char *p) { return s.compare(at, strlen(p), p) == 0; }

static void replace_all(std::string &s, const std::string &from, const std::string &to) {
    for (size_t at = 0; (at = s.find(from, at)) != std::string::npos; at += to.size()) s.replace(at, from.size(), to);
}

static bool ident_char(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'; }

// replace whole-word occurrences of `from` (followed by '(' when call is set)
static void replace_word(std::string &s, const std::string &from, const std::string &to, bool call) {
    for (size_t at = 0; (at = s.find(from, at)) != std::string::npos; ) {
        size_t end = at + from.size();
        bool ok = (at == 0 || !ident_char(s[at - 1])) && (end >= s.size() || !ident_char(s[end]));
        if (ok && call) {
            size_t k = end;
            while (k < s.size() && s[k] == ' ') k++;
            ok = k < s.size() && s[k] == '(';
        }
        if (ok) { s.replace(at, from.size(), to); at += to.size(); }
        else at = end;
    }
}

// a declaration line "uniform <type> <name>[<n>];" (with optional /*ndabl*/ or bindable prefix)
static bool parse_uniform(const std::string &line, std::string &type, std::string &name, int &count) {
    std::string s = line;
    replace_all(s, "/*ndabl*/", "");
    size_t k = s.find_first_not_of(" \t");
    if (k == std::string::npos) return false;
    if (starts(s, k, "bindable ")) k += 9;
    if (!starts(s, k, "uniform ")) return false;
    k += 8;
    size_t t1 = s.find(' ', k);
    if (t1 == std::string::npos) return false;
    type = s.substr(k, t1 - k);
    size_t n0 = s.find_first_not_of(' ', t1);
    size_t n1 = n0;
    while (n1 < s.size() && ident_char(s[n1])) n1++;
    name = s.substr(n0, n1 - n0);
    count = 1;
    if (n1 < s.size() && s[n1] == '[') count = atoi(s.c_str() + n1 + 1);
    return !name.empty() && s.find(';') != std::string::npos;
}

static int kind_of(const std::string &type) {
    if (type == "vec4") return MGL_VEC4;
    if (type == "ivec4") return MGL_IVEC4;
    if (type == "bool") return MGL_BOOL;
    if (type == "sampler2D") return MGL_SAMPLER2D;
    if (type == "samplerCube") return MGL_SAMPLERCUBE;
    if (type == "float") return MGL_FLOAT;
    if (type == "vec2") return MGL_VEC2;
    if (type == "vec3") return MGL_VEC3;
    if (type == "int") return MGL_INT;
    if (type == "mat4") return MGL_MAT4;
    return -1;
}

static std::vector<std::string> split_lines(const char *src) {
    std::vector<std::string> v;
    std::string s(src);
    size_t at = 0;
    while (at <= s.size()) {
        size_t nl = s.find('\n', at);
        if (nl == std::string::npos) { v.push_back(s.substr(at)); break; }
        v.push_back(s.substr(at, nl - at));
        at = nl + 1;
    }
    return v;
}

int mgl_reflect(const char *src, int stage, MglUniform *out, int max, int *block_size, int *bias_offset) {
    int n = 0, offset = 0, sampler = 0;
    for (const std::string &ln : split_lines(src)) {
        std::string type, name;
        int count;
        if (!parse_uniform(ln, type, name, count)) continue;
        int kind = kind_of(type);
        if (kind < 0 || n == max) return -1;
        MglUniform *u = &out[n++];
        memset(u, 0, sizeof *u);
        snprintf(u->name, sizeof u->name, "%s", name.c_str());
        u->stage = stage; u->kind = kind; u->count = count;
        if (kind == MGL_SAMPLER2D || kind == MGL_SAMPLERCUBE) { u->binding = sampler++; u->offset = -1; continue; }
        // std140: arrays and vec4-class members take 16 bytes per element (mat4 = 4 vec4s)
        int elem = kind == MGL_MAT4 ? 64 : 16;
        if (count == 1 && (kind == MGL_FLOAT || kind == MGL_INT || kind == MGL_BOOL)) elem = 4;
        if (count == 1 && kind == MGL_VEC2) elem = 8;
        int align = (count > 1 || kind == MGL_VEC4 || kind == MGL_IVEC4 || kind == MGL_VEC3 || kind == MGL_MAT4) ? 16 : elem;
        offset = (offset + align - 1) / align * align;
        u->offset = offset;
        u->stride = count > 1 ? (kind == MGL_MAT4 ? 64 : 16) : elem;
        offset += count > 1 ? u->stride * count : elem;
    }
    // fragment shaders that sample get "vec4 SC_LodBias[4]" (per-sampler GL texture-unit LOD bias) last
    *bias_offset = -1;
    if (stage == MGL_FRAGMENT && sampler) { offset = (offset + 15) / 16 * 16; *bias_offset = offset; offset += 64; }
    *block_size = (offset + 15) / 16 * 16;
    return n;
}

// add the unit LOD bias to implicit-LOD lookups: fn(SamplerN, ...) -> fn(SamplerN, ..., SC_LodBias[i/4][i%4]).
// A bias of 1024 or more flags a mask texture (mgl.m, classify_mask): texture2D lookups become SC_Tex2D,
// which sharpens a magnified mask's alpha edges; other lookups just drop the flag.
static void add_bias(std::string &body, const std::string &fn, const std::vector<std::string> &samplers) {
    for (size_t at = 0; (at = body.find(fn, at)) != std::string::npos; ) {
        size_t end = at + fn.size();
        bool word = (at == 0 || !ident_char(body[at - 1])) && end < body.size() && !ident_char(body[end]);
        size_t k = end;
        while (word && k < body.size() && body[k] == ' ') k++;
        if (!word || k >= body.size() || body[k] != '(') { at = end; continue; }
        size_t a0 = body.find_first_not_of(' ', k + 1), a1 = a0;
        while (a1 < body.size() && ident_char(body[a1])) a1++;
        std::string first = body.substr(a0, a1 - a0);
        int depth = 0;
        size_t close = k;
        for (; close < body.size(); close++) {
            if (body[close] == '(') depth++;
            else if (body[close] == ')' && --depth == 0) break;
        }
        int idx = -1;
        for (size_t i = 0; i < samplers.size(); i++) if (samplers[i] == first) idx = (int)i;
        if (idx >= 0 && close < body.size()) {
            std::string v = "SC_LodBias[" + std::to_string(idx / 4) + "][" + std::to_string(idx % 4) + "]";
            std::string b = fn == "texture2D" ? ", " + v : ", SC_Bias(" + v + ")";
            body.insert(close, b);
            close += b.size();
            if (fn == "texture2D") { body.replace(at, fn.size(), "SC_Tex2D"); close += 8 - fn.size(); }
        }
        at = close;
    }
}

// GLSL 1.20 -> 4.50 for glslang (Vulkan semantics)
static std::string upgrade(const char *src, int stage, const MglAttrib *attrs, int nattrs) {
    std::vector<std::string> lines = split_lines(src);
    std::string block, samplers, inits, body;
    std::vector<std::string> snames;
    int sampler = 0, next_loc = 0;
    for (int k = 0; k < nattrs; k++) if (attrs[k].location >= next_loc) next_loc = attrs[k].location + 1;
    for (std::string ln : lines) {
        size_t k = ln.find_first_not_of(" \t");
        if (k != std::string::npos && (starts(ln, k, "#version") || starts(ln, k, "#extension"))) continue;
        std::string type, name;
        int count;
        if (parse_uniform(ln, type, name, count)) {
            int kind = kind_of(type);
            std::string decl = type + " " + name + (count > 1 || ln.find('[') != std::string::npos ? "[" + std::to_string(count) + "]" : "") + ";";
            if (kind == MGL_SAMPLER2D || kind == MGL_SAMPLERCUBE) {
                samplers += "layout(set=0, binding=" + std::to_string(1 + sampler++) + ") uniform " + decl + "\n";
                snames.push_back(name);
            }
            else block += "    " + decl + "\n";
            continue;
        }
        if (stage == MGL_VERTEX && k != std::string::npos && starts(ln, k, "attribute ")) {
            // attribute vec4 NAME;  ->  layout(location=L) in vec4 NAME;
            std::string rest = ln.substr(k + 10);
            size_t sp = rest.find(' ');
            std::string an = rest.substr(sp + 1);
            an = an.substr(0, an.find(';'));
            while (!an.empty() && an.back() == ' ') an.pop_back();
            int loc = -1;
            for (int a = 0; a < nattrs; a++) if (!strcmp(attrs[a].name, an.c_str())) loc = attrs[a].location;
            if (loc < 0) loc = next_loc++;
            body += "layout(location=" + std::to_string(loc) + ") in " + rest + "\n";
            continue;
        }
        // non-constant global initialisers ("vec4 X = _X;") move into main()
        if (k == 0 && ln.find(" = _") != std::string::npos && ln.find('(') == std::string::npos) {
            size_t eq = ln.find(" = ");
            size_t sp = ln.find(' ');
            if (sp < eq) {
                inits += ln.substr(sp + 1) + "\n";
                body += ln.substr(0, eq) + ";\n";
                continue;
            }
        }
        body += ln + "\n";
    }
    if (stage == MGL_FRAGMENT && !snames.empty()) {   // must match mgl_reflect's bias_offset
        block += "    vec4 SC_LodBias[4];\n";
        for (const char *fn : {"texture2DProj", "texture2D", "textureCube"}) add_bias(body, fn, snames);
    }
    std::string decl;
    if (!block.empty()) decl += "layout(std140, set=0, binding=0) uniform SC_Block {\n" + block + "};\n";
    decl += samplers;
    if (stage == MGL_FRAGMENT && !snames.empty())
        decl += "float SC_Bias(float b) { return b < 512.0 ? b : b - 1024.0; }\n"
                // alpha edges of a magnified mask, bilinearly blurred over several pixels, are cut to about
                // one pixel; smooth gradients (alpha changing slowly per texel) and minified use are left alone
                "vec4 SC_Tex2D(sampler2D s, vec2 uv, float b) {\n"
                "    if (b < 512.0) return texture(s, uv, b);\n"
                "    vec4 c = texture(s, uv, b - 1024.0);\n"
                "    vec2 tx = fwidth(uv * vec2(textureSize(s, 0)));\n"
                "    float mag = max(tx.x, tx.y);\n"
                "    float fa = max(fwidth(c.a), 1e-5);\n"
                "    float slope = fa / max(mag, 1e-5);\n"
                "    float k = smoothstep(0.2, 0.4, slope) * (1.0 - smoothstep(0.6, 1.0, mag));\n"
                "    c.a = mix(c.a, clamp((c.a - 0.5) / fa + 0.5, 0.0, 1.0), k);\n"
                "    return c;\n"
                "}\n";
    char tmp[64];
    if (stage == MGL_VERTEX) {
        for (int n = 0; n < 8; n++) {
            snprintf(tmp, sizeof tmp, "gl_TexCoord[%d]", n);
            if (body.find(tmp) == std::string::npos) continue;
            replace_all(body, tmp, "SC_TexCoord" + std::to_string(n));
            decl += "layout(location=" + std::to_string(n) + ") out vec4 SC_TexCoord" + std::to_string(n) + ";\n";
        }
        if (body.find("gl_FrontColor") != std::string::npos) {
            replace_all(body, "gl_FrontColor", "SC_Color");
            decl += "layout(location=8) out vec4 SC_Color;\n";
        }
        if (body.find("gl_FrontSecondaryColor") != std::string::npos) {
            replace_all(body, "gl_FrontSecondaryColor", "SC_Color2");
            decl += "layout(location=9) out vec4 SC_Color2;\n";
        }
        if (body.find("gl_Back") != std::string::npos) {
            replace_word(body, "gl_BackColor", "SC_Unused", false);
            replace_word(body, "gl_BackSecondaryColor", "SC_Unused", false);
            decl += "vec4 SC_Unused;\n";
        }
    } else {
        for (int n = 0; n < 8; n++) {
            snprintf(tmp, sizeof tmp, "gl_TexCoord[%d]", n);
            if (body.find(tmp) == std::string::npos) continue;
            replace_all(body, tmp, "SC_TexCoord" + std::to_string(n));
            decl += "layout(location=" + std::to_string(n) + ") in vec4 SC_TexCoord" + std::to_string(n) + ";\n";
        }
        if (body.find("gl_SecondaryColor") != std::string::npos) {
            replace_all(body, "gl_SecondaryColor", "SC_Color2");
            decl += "layout(location=9) in vec4 SC_Color2;\n";
        }
        if (body.find("gl_Color") != std::string::npos) {
            replace_word(body, "gl_Color", "SC_Color", false);
            decl += "layout(location=8) in vec4 SC_Color;\n";
        }
        if (body.find("gl_FragColor") != std::string::npos) replace_all(body, "gl_FragColor", "gl_FragData[0]");
        for (int n = 0; n < 4; n++) {
            snprintf(tmp, sizeof tmp, "gl_FragData[%d]", n);
            if (body.find(tmp) == std::string::npos) continue;
            replace_all(body, tmp, "SC_FragData" + std::to_string(n));
            decl += "layout(location=" + std::to_string(n) + ") out vec4 SC_FragData" + std::to_string(n) + ";\n";
        }
    }
    static const char *const fns[][2] = {
        {"texture2DProjLod", "textureProjLod"}, {"texture2DProj", "textureProj"}, {"texture2DLod", "textureLod"},
        {"texture2D", "texture"}, {"textureCubeLod", "textureLod"}, {"textureCube", "texture"},
        {"shadow2DProj", "textureProj"}, {"shadow2D", "texture"}, {"texture3DLod", "textureLod"}, {"texture3D", "texture"}};
    for (auto &f : fns) replace_word(body, f[0], f[1], true);
    if (!inits.empty()) {
        size_t m = body.find("void main()");
        if (m != std::string::npos) {
            size_t brace = body.find('{', m);
            if (brace != std::string::npos) body.insert(brace + 1, "\n" + inits);
        }
    }
    return "#version 450\n" + decl + body;
}

static void seterr(char *err, size_t errlen, const char *fmt, ...) {
    if (!err || !errlen) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

static int glslang_ready;
void mgl_shader_init(void) { if (!glslang_ready) { glslang_initialize_process(); glslang_ready = 1; } }

char *mgl_to_msl(const char *src, int stage, const MglAttrib *attrs, int nattrs, char **glsl450, char *err, size_t errlen) {
    if (!glslang_ready) { glslang_initialize_process(); glslang_ready = 1; }
    std::string g = upgrade(src, stage, attrs, nattrs);
    if (glsl450) *glsl450 = strdup(g.c_str());
    glslang_stage_t gs = stage == MGL_VERTEX ? GLSLANG_STAGE_VERTEX : GLSLANG_STAGE_FRAGMENT;
    glslang_input_t in = {};
    in.language = GLSLANG_SOURCE_GLSL;
    in.stage = gs;
    in.client = GLSLANG_CLIENT_VULKAN;
    in.client_version = GLSLANG_TARGET_VULKAN_1_0;
    in.target_language = GLSLANG_TARGET_SPV;
    in.target_language_version = GLSLANG_TARGET_SPV_1_0;
    in.code = g.c_str();
    in.default_version = 450;
    in.default_profile = GLSLANG_NO_PROFILE;
    in.messages = (glslang_messages_t)(GLSLANG_MSG_DEFAULT_BIT | GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT);
    in.resource = glslang_default_resource();
    glslang_shader_t *sh = glslang_shader_create(&in);
    char *result = NULL;
    glslang_program_t *prog = NULL;
    spvc_context ctx = NULL;
    if (!glslang_shader_preprocess(sh, &in) || !glslang_shader_parse(sh, &in)) {
        seterr(err, errlen, "glslang: %s", glslang_shader_get_info_log(sh));
        goto done;
    }
    prog = glslang_program_create();
    glslang_program_add_shader(prog, sh);
    if (!glslang_program_link(prog, GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT)) {
        seterr(err, errlen, "glslang link: %s", glslang_program_get_info_log(prog));
        goto done;
    }
    glslang_program_SPIRV_generate(prog, gs);
    {
        spvc_parsed_ir ir;
        spvc_compiler comp;
        spvc_compiler_options opts;
        const char *msl = NULL;
        if (spvc_context_create(&ctx) != SPVC_SUCCESS) { seterr(err, errlen, "spvc context"); goto done; }
        if (spvc_context_parse_spirv(ctx, glslang_program_SPIRV_get_ptr(prog), glslang_program_SPIRV_get_size(prog), &ir) != SPVC_SUCCESS ||
            spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &comp) != SPVC_SUCCESS) {
            seterr(err, errlen, "spirv-cross parse: %s", spvc_context_get_last_error_string(ctx));
            goto done;
        }
        spvc_compiler_create_compiler_options(comp, &opts);
        spvc_compiler_options_set_uint(opts, SPVC_COMPILER_OPTION_MSL_VERSION, SPVC_MAKE_MSL_VERSION(2, 1, 0));
        spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, stage == MGL_VERTEX);
        spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_FIXUP_DEPTH_CONVENTION, stage == MGL_VERTEX);
        spvc_compiler_install_compiler_options(comp, opts);
        SpvExecutionModel model = stage == MGL_VERTEX ? SpvExecutionModelVertex : SpvExecutionModelFragment;
        spvc_msl_resource_binding b;
        spvc_msl_resource_binding_init(&b);
        b.stage = model; b.desc_set = 0; b.binding = 0; b.msl_buffer = 0;
        spvc_compiler_msl_add_resource_binding(comp, &b);
        for (unsigned k = 0; k < 16; k++) {
            spvc_msl_resource_binding_init(&b);
            b.stage = model; b.desc_set = 0; b.binding = 1 + k; b.msl_texture = k; b.msl_sampler = k;
            spvc_compiler_msl_add_resource_binding(comp, &b);
        }
        if (spvc_compiler_compile(comp, &msl) != SPVC_SUCCESS) {
            seterr(err, errlen, "spirv-cross: %s", spvc_context_get_last_error_string(ctx));
            goto done;
        }
        result = strdup(msl);
    }
done:
    if (ctx) spvc_context_destroy(ctx);
    if (prog) glslang_program_delete(prog);
    glslang_shader_delete(sh);
    return result;
}
