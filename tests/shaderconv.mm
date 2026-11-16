// Converts every shader in a directory (*.glsl dumps from RT_GLTRACE_ALL, or *.vert/*.frag) with
// mgl_to_msl and compiles the result with Metal. usage: shaderconv DIR [max]
#import <Metal/Metal.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "mgl_shader.h"

static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *b = (char *)malloc(n + 1); fread(b, 1, n, f); b[n] = 0; fclose(f);
    return b;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        DIR *d = opendir(argv[1]);
        int max = argc > 2 ? atoi(argv[2]) : 1 << 30, n = 0, conv_fail = 0, metal_fail = 0, refl_fail = 0;
        double t_conv = 0, t_metal = 0;
        struct dirent *e;
        while ((e = readdir(d)) && n < max) {
            if (e->d_name[0] == '.') continue;
            char path[1024];
            snprintf(path, sizeof path, "%s/%s", argv[1], e->d_name);
            char *src = slurp(path);
            if (!src) continue;
            int stage = (strstr(src, "gl_Position") ? MGL_VERTEX : MGL_FRAGMENT);
            n++;
            MglUniform u[64];
            int bs;
            int bo; if (mgl_reflect(src, stage, u, 64, &bs, &bo) < 0) { if (refl_fail++ < 3) printf("reflect failed: %s\n", path); }
            char err[2048];
            struct timespec a, b, c;
            clock_gettime(CLOCK_MONOTONIC, &a);
            char *msl = mgl_to_msl(src, stage, NULL, 0, NULL, err, sizeof err);
            clock_gettime(CLOCK_MONOTONIC, &b);
            t_conv += (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) * 1e-9;
            if (!msl) { if (conv_fail++ < 5) printf("convert failed: %s\n  %.300s\n", path, err); free(src); continue; }
            NSError *ne = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:nil error:&ne];
            clock_gettime(CLOCK_MONOTONIC, &c);
            t_metal += (c.tv_sec - b.tv_sec) + (c.tv_nsec - b.tv_nsec) * 1e-9;
            if (!lib) { if (metal_fail++ < 5) printf("metal failed: %s\n  %.300s\n", path, ne.localizedDescription.UTF8String); }
            [lib release];
            free(msl); free(src);
        }
        printf("%d shaders: %d reflect failures, %d conversion failures, %d Metal failures\n", n, refl_fail, conv_fail, metal_fail);
        printf("average: convert %.2f ms, Metal compile %.2f ms\n", 1000 * t_conv / n, 1000 * t_metal / n);
    }
    return 0;
}
