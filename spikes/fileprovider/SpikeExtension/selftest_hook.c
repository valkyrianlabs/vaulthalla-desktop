// THROWAWAY SPIKE: SPIKE_SELFTEST=1 runs the extension binary's own self-test, inside its sandbox, before
// NSExtensionMain (so Q2 can be checked with the extension's exact signature without the File Provider runtime).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
extern void spike_extension_selftest(int sandboxed);

__attribute__((constructor)) static void spike_selftest_hook(void) {
    const char *flag = getenv("SPIKE_SELFTEST");
    if (flag == NULL || strcmp(flag, "1") != 0) return;
    int sandboxed = sandbox_check(getpid(), NULL, 0);
    spike_extension_selftest(sandboxed);
    exit(0);
}
