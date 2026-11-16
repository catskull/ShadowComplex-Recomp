// RT_GLCOUNT=1: count calls to each OpenGL entry point and print per-frame averages every two
// seconds (to see what splits Apple's GL-on-Metal render passes). Thunks call GLCOUNT(name).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "rt.h"

int rt_glcount_on = -1;
#define MAXN 256
static const char *names[MAXN];
static uint64_t counts[MAXN];
static int n;

void rt_glcount_hit(int *slot, const char *name) {
    if (rt_glcount_on < 0) rt_glcount_on = getenv("RT_GLCOUNT") != 0;
    if (rt_glargs_on < 0) rt_glargs_on = getenv("RT_GLARGS") != 0;
    if (!rt_glcount_on) return;
    if (*slot < 0) {
        if (n == MAXN) return;
        names[n] = name; *slot = n++;
    }
    counts[*slot]++;
}

void rt_glcount_frame(void) {
    static uint64_t frames, t0;
    if (rt_glcount_on <= 0) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (!t0) t0 = now;
    frames++;
    if (now - t0 < 2000000000ull) return;
    int idx[MAXN];
    for (int k = 0; k < n; k++) idx[k] = k;
    for (int a = 0; a < n; a++)                 // sort by count, descending
        for (int b = a + 1; b < n; b++)
            if (counts[idx[b]] > counts[idx[a]]) { int t = idx[a]; idx[a] = idx[b]; idx[b] = t; }
    fprintf(stderr, "glcount: per frame over %llu frames:", (unsigned long long)frames);
    for (int k = 0; k < n && counts[idx[k]]; k++)
        fprintf(stderr, " %s %.1f", names[idx[k]], (double)counts[idx[k]] / frames);
    fprintf(stderr, "\n");
    memset(counts, 0, sizeof counts);
    frames = 0; t0 = now;
}

// RT_GLARGS=1: log each distinct combination of a GL call's arguments once (values that look like
// GL enums or small integers are kept, others shown as '*'; float arguments are kept)
int rt_glargs_on = -1;
void rt_glargs(const char *name, const uint64_t *a, int n, const double *f, int nf) {
    static char *seen[16384];
    static int nseen;
    if (rt_glargs_on < 0) rt_glargs_on = getenv("RT_GLARGS") != 0;
    if (!rt_glargs_on) return;
    static int percall[1024];
    char b[256];
    int len = snprintf(b, sizeof b, "%s(", name);
    for (int k = 0; k < n && len < 200; k++) {
        uint64_t v = a[k];
        if (v < 0x40 || (v >= 0x0200 && v < 0x10000)) len += snprintf(b + len, sizeof b - len, "%s0x%llx", k ? ", " : "", (unsigned long long)v);
        else len += snprintf(b + len, sizeof b - len, "%s*", k ? ", " : "");
    }
    for (int k = 0; k < nf && len < 230; k++) len += snprintf(b + len, sizeof b - len, "%s%g", (n || k) ? ", " : "", f[k]);
    snprintf(b + len, sizeof b - len, ")");
    for (int k = 0; k < nseen; k++) if (!strcmp(seen[k], b)) return;
    unsigned h = 0;
    for (const char *p = name; *p; p++) h = h * 31 + (unsigned char)*p;
    if (percall[h % 1024]++ >= 64) return;           // cap noisy functions
    if (nseen < 16384) seen[nseen++] = strdup(b);
    fprintf(stderr, "glargs: %s\n", b);
}
