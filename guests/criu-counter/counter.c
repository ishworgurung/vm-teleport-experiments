/* Phase 4: a native counter for the CRIU negative controls.
 *
 * The same counter as the Wasm guests, compiled to x86-64 machine code and
 * linked against the system glibc. Each line goes through snprintf, strlen
 * and write. glibc picks the string routines once, at load time, through
 * IFUNC resolvers that read CPUID: on a CPU with AVX2 it binds strlen to an
 * AVX2 version. CRIU saves the process with those choices baked into its
 * memory, so a restore on a CPU without AVX2 runs AVX2 code anyway.
 */
/* snprintf(). */
#include <stdio.h>
/* strlen(). */
#include <string.h>
/* write(), getpid(), usleep() and STDOUT_FILENO. */
#include <unistd.h>

/* The program runs until it is killed. */
int main(void)
{
    /* A buffer for one output line. */
    char line[96];
    /* Count from 1 for ever.  There is no end condition, because CRIU saves the process while it runs. */
    for (unsigned long n = 1;; n++) {
        /* Format one line: the counter and the process id.  The process id shows that a restored process is the same one. */
        snprintf(line, sizeof line, "criu-counter n=%lu pid=%d\n", n, getpid());
        /* Write the line to standard output.  A negative result is an error. */
        if (write(STDOUT_FILENO, line, strlen(line)) < 0)
            /* Stop with a failure status if write() failed. */
            return 1;
        /* Wait 200 ms (usleep takes microseconds), so that the output is slow enough to read. */
        usleep(200 * 1000);
    }
}
