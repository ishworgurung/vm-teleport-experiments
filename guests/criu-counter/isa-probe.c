/* Does this (virtual) CPU *run* AVX and AVX2 instructions, whatever CPUID says?
 *
 * Prints the CPUID bits for AVX (leaf 1 ECX bit 28) and AVX2 (leaf 7 EBX bit
 * 5), and XCR0 (read with XGETBV), whose bit 2 enables the YMM register
 * state. Then executes one AVX and one AVX2 instruction, each in a child
 * process, and reports whether it ran or died with SIGILL.
 *
 * Under KVM the guest runs on the real core. A hypervisor can hide a feature
 * in CPUID, but it can only *disable* instructions through XCR0 state
 * components (YMM for AVX, ZMM and opmask for AVX-512): an instruction whose
 * state is enabled runs even if CPUID denies it.
 */
/* __cpuid() and __cpuid_count(): wrappers for the CPUID instruction. */
#include <cpuid.h>
/* SIGILL. */
#include <signal.h>
/* printf(). */
#include <stdio.h>
/* waitpid(), WIFSIGNALED and WTERMSIG. */
#include <sys/wait.h>
/* fork() and _exit(). */
#include <unistd.h>

/* Run `fn` in a child process, and report whether it ran or was killed by a signal.
 * The child process isolates the fault: a SIGILL kills only the child. */
static void try(const char *name, void (*fn)(void))
{
    /* Create the child process.  In the child, fork() returns 0. */
    pid_t p = fork();
    /* In the child: run the instruction, then leave with status 0.  _exit() skips the cleanup that exit() does, which is right in a forked child. */
    if (p == 0) { fn(); _exit(0); }
    /* st receives the exit status of the child. */
    int st;
    /* Wait for the child to end. */
    waitpid(p, &st, 0);
    /* If a signal killed the child: */
    if (WIFSIGNALED(st))
        /* Print the name of the test and the signal number.  The text says whether the signal was SIGILL. */
        printf("  %-34s -> killed by signal %d (%s)\n", name, WTERMSIG(st),
               WTERMSIG(st) == SIGILL ? "SIGILL: invalid opcode" : "other");
    /* The child ended normally, so the instruction ran. */
    else
        printf("  %-34s -> ran\n", name);
}

/* vxorps ymm0, ymm0, ymm0 is a 256-bit (AVX) instruction.  It sets ymm0 to 0, because a
 * register xor itself is 0.  The clobber "xmm0" tells the compiler that xmm0 (the low half of
 * ymm0) changes.  If the CPU or the runtime lacks AVX, the CPU raises an invalid-opcode
 * fault and the process gets SIGILL. */
static void avx(void)  { __asm__ volatile("vxorps %%ymm0, %%ymm0, %%ymm0" ::: "xmm0"); }
/* vpaddd ymm0, ymm0, ymm0 adds eight 32-bit integers at once.  It is an AVX2
 * instruction, so a CPU with AVX but not AVX2 raises SIGILL here. */
static void avx2(void) { __asm__ volatile("vpaddd %%ymm0, %%ymm0, %%ymm0" ::: "xmm0"); }

/* The program starts here. */
int main(void)
{
    /* The four result registers of CPUID. */
    unsigned a, b, c, d;
    /* Run CPUID leaf 1.  ECX bit 28 is the AVX flag, and ECX bit 27 is OSXSAVE (the OS saves the extended state). */
    __cpuid(1, a, b, c, d);
    /* Pick out the two bits. */
    int has_avx = (c >> 28) & 1, has_osxsave = (c >> 27) & 1;
    /* Run CPUID leaf 7, sub-leaf 0.  EBX bit 5 is the AVX2 flag. */
    __cpuid_count(7, 0, a, b, c, d);
    /* Pick out that bit. */
    int has_avx2 = (b >> 5) & 1;
    /* Print the three flags. */
    printf("CPUID: AVX=%d AVX2=%d OSXSAVE=%d\n", has_avx, has_avx2, has_osxsave);
    /* If the OS supports XSAVE, we may read XCR0: */
    if (has_osxsave) {
        /* lo and hi are the low and high halves of XCR0. */
        unsigned lo, hi;
        /* xgetbv reads an extended control register.  ecx = 0 selects XCR0, which says which
         * CPU state the operating system saves on a context switch.  "=a"(lo) and "=d"(hi) receive
         * the low and high halves, and "c"(0) sets ecx first.  Bit 2 of XCR0 means the OS saves the
         * YMM registers, so AVX code is allowed to run. */
        __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
        /* Print XCR0.  Bit 2 of it enables the state of the YMM registers. */
        printf("XCR0 = 0x%x (bit 2, YMM state: %s)\n", lo, (lo & 4) ? "enabled" : "disabled");
    } else {
        /* Without OSXSAVE, the xgetbv instruction would fault, so we do not run it. */
        printf("XCR0: no XSAVE, so no YMM state\n");
    }
    /* Test an AVX instruction in a child process. */
    try("AVX:  vxorps ymm0, ymm0, ymm0", avx);
    /* Test an AVX2 instruction in a child process. */
    try("AVX2: vpaddd ymm0, ymm0, ymm0", avx2);
    /* Report success. */
    return 0;
}
