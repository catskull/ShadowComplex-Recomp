// Measures compiling N converted shaders as one Metal library (each in its own namespace) against
// compiling them one by one. usage: batchcompile DIR N
#import <Metal/Metal.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <time.h>
#include "mgl_shader.h"
static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *b = (char *)malloc(n + 1); fread(b, 1, n, f); b[n] = 0; fclose(f); return b;
}
static double ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        MTLCompileOptions *o = [[MTLCompileOptions alloc] init];
        o.preserveInvariance = YES;
        mgl_shader_init();
        int N = atoi(argv[2]), n = 0, skip = argc > 3 ? atoi(argv[3]) : 0;
        DIR *d = opendir(argv[1]);
        struct dirent *e;
        std::string batch = "#include <metal_stdlib>\n#include <simd/simd.h>\nusing namespace metal;\n";
        while ((e = readdir(d)) && n < N) {
            if (e->d_name[0] == '.') continue;
            if (skip-- > 0) continue;
            char path[1024]; snprintf(path, sizeof path, "%s/%s", argv[1], e->d_name);
            char *src = slurp(path);
            int stage = strstr(src, "gl_Position") ? MGL_VERTEX : MGL_FRAGMENT;
            char err[512];
            char *msl = mgl_to_msl(src, stage, NULL, 0, NULL, err, sizeof err);
            if (!msl) continue;
            std::string m(msl);
            // drop the preamble lines (#pragma/#include/using) - keep everything else inside a namespace
            std::string body;
            size_t at = 0;
            while (at < m.size()) {
                size_t nl = m.find('\n', at); if (nl == std::string::npos) nl = m.size();
                std::string ln = m.substr(at, nl - at);
                if (ln.rfind("#include", 0) != 0 && ln.rfind("using namespace", 0) != 0 && ln.rfind("#pragma", 0) != 0) body += ln + "\n";
                at = nl + 1;
            }
            batch += "namespace s" + std::to_string(n) + " {\n" + body + "}\n";
            n++; free(msl); free(src);
        }
        double t0 = ms();
        NSError *ne = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:batch.c_str()] options:o error:&ne];
        double t1 = ms();
        if (!lib) { printf("batch failed: %.600s\n", ne.localizedDescription.UTF8String); return 1; }
        printf("%d shaders in one library: %.0f ms (%.1f ms each)\n", n, t1 - t0, (t1 - t0) / n);
        NSArray *names = [lib functionNames];
        printf("functions: %lu, e.g. %s\n", (unsigned long)names.count, names.count ? [names[0] UTF8String] : "-");
        id<MTLFunction> f = [lib newFunctionWithName:@"s0::main0"];
        printf("lookup s0::main0: %s\n", f ? "ok" : "not found");
    }
    return 0;
}
