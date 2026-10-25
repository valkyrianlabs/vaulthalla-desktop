// Debug builds only: runs the extension's self-check (ExtensionContext.swift) before NSExtensionMain when
// VH_FILEPROVIDER_SELFCHECK names a domain, then exits. Release builds compile nothing here.
#ifdef DEBUG
#include <stdlib.h>

extern void vh_fileprovider_selfcheck(const char *domain_identifier);

__attribute__((constructor)) static void vh_fileprovider_selfcheck_hook(void) {
    const char *identifier = getenv("VH_FILEPROVIDER_SELFCHECK");
    if (identifier == NULL || identifier[0] == '\0') return;
    vh_fileprovider_selfcheck(identifier);
    exit(0);
}
#endif
