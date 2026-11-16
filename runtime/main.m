// Launcher: load the original game binary from the Steam install, set up the Objective-C
// bridge, run static initializers and enter the guest's main (which calls NSApplicationMain).
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <pthread.h>
#include <sys/ucontext.h>
#include <signal.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "abi.h"
#include "image.h"

void rt_objc_init(void);

#define DEFAULT_GAME "Library/Application Support/Steam/steamapps/common/Shadow Complex Remastered/" \
                     "Shadow Complex Remastered.app/Contents/MacOS/ShadowComplexRemastered"

// guest frames keep rbp chains; return addresses are G(link address) values pushed by translated calls
static void guest_backtrace(CPU *c) {
    fprintf(stderr, "guest backtrace (link addresses; symbolize with tools/symbolize.py):\n  0x%llx\n", (unsigned long long)c->fn);
    uint64_t bp = c->rbp;
    for (int k = 0; k < 64 && bp >= c->stack_lo && bp + 16 <= c->stack_hi; k++) {
        uint64_t ret = rd64(bp + 8);
        if (ret < GSLIDE) break;
        fprintf(stderr, "  0x%llx\n", (unsigned long long)(ret - GSLIDE));
        uint64_t next = rd64(bp);
        if (next <= bp) break;
        bp = next;
    }
}

static void on_crash(int sig, siginfo_t *si, void *ucv) {
    ucontext_t *uc = ucv;
    CPU *c = rt_cpu();
    fprintf(stderr, "\nfatal signal %d at address %p, thread %p\n", sig, si->si_addr, (void *)pthread_self());
    void *pc = (void *)uc->uc_mcontext->__ss.__pc;
    Dl_info di = {0};
    if (dladdr(pc, &di) && di.dli_sname)
        fprintf(stderr, "host pc %p = %s+0x%lx (%s)\n", pc, di.dli_sname, (long)((char *)pc - (char *)di.dli_saddr),
                di.dli_fname ? strrchr(di.dli_fname, '/') + 1 : "?");
    fprintf(stderr, "guest rax=%llx rbx=%llx rcx=%llx rdx=%llx rsi=%llx rdi=%llx rbp=%llx rsp=%llx\n"
                    "      r8=%llx r9=%llx r10=%llx r11=%llx r12=%llx r13=%llx r14=%llx r15=%llx\n",
            C.rax, C.rbx, C.rcx, C.rdx, C.rsi, C.rdi, C.rbp, C.rsp, C.r8, C.r9, C.r10, C.r11, C.r12, C.r13, C.r14, C.r15);
    guest_backtrace(c);
    signal(sig, SIG_DFL);
    raise(sig);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Terminal's default limit is 256 open files: the Metal renderer's cached shader libraries (one
        // open file each) plus the game's packages exceed it, and a package that fails to open crashes
        // the loader. Raise it to the system maximum.
        struct rlimit rl;
        if (!getrlimit(RLIMIT_NOFILE, &rl)) {
            rlim_t want = rl.rlim_max < OPEN_MAX ? rl.rlim_max : OPEN_MAX;
            if (rl.rlim_cur < want) { rl.rlim_cur = want; setrlimit(RLIMIT_NOFILE, &rl); }
        }
        struct sigaction sa = {0};
        sa.sa_sigaction = on_crash;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        stack_t ss = {.ss_sp = malloc(1 << 17), .ss_size = 1 << 17};
        sigaltstack(&ss, 0);
        int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP};
        for (int k = 0; k < 6; k++) sigaction(sigs[k], &sa, 0);

        char path[2048];
        // the game binary: SCR_GAME_BINARY, else the copy the app was built from (SCRGameBinary in Info.plist,
        // set by the Makefile), else the default Steam library
        const char *game = getenv("SCR_GAME_BINARY");
        NSString *built = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SCRGameBinary"];
        if (!game && built.length) game = built.UTF8String;
        if (!game) { snprintf(path, sizeof path, "%s/" DEFAULT_GAME, getenv("HOME")); game = path; }
        if (access(game, R_OK)) {
            fprintf(stderr, "cannot read the game binary at %s (%s)\nset SCR_GAME_BINARY to the ShadowComplexRemastered executable\n",
                    game, strerror(errno));
            return 1;
        }
        rt_metal = getenv("RT_METAL") != 0;
        if (rt_metal) mgl_init();
        if (rt_load_image(game)) return 1;
        CPU *c = rt_new_cpu(64 << 20);     // the main thread runs the engine
        rt_set_cpu(c);
        rt_objc_init();
        for (int k = 0; k < ngmodinit; k++) rt_call(c, gmodinit[k]);
    }
    // the guest's argv: same strings, guest-readable since memory is shared
    CPU *c = rt_cpu();
    C.rdi = (uint64_t)argc;
    C.rsi = (uint64_t)argv;
    rt_call(c, gentry);
    return (int)C.rax;
}
