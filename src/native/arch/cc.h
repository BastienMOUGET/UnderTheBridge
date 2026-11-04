/* arch/cc.h — portage lwIP minimal (MinGW-w64 et Linux/gcc). */
#ifndef BRIDGE_LWIP_ARCH_CC_H
#define BRIDGE_LWIP_ARCH_CC_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>

#define LWIP_NO_UNISTD_H        1
#define LWIP_TIMEVAL_PRIVATE    0
#define LWIP_ERRNO_STDINCLUDE   1

#ifndef BYTE_ORDER
#  define BYTE_ORDER LITTLE_ENDIAN   /* x86 / x64 / ARM64 Windows */
#endif
#ifndef LITTLE_ENDIAN
#  define LITTLE_ENDIAN 1234
#endif
#ifndef BIG_ENDIAN
#  define BIG_ENDIAN 4321
#endif

#define LWIP_PLATFORM_DIAG(x)   do { printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(x) do { fprintf(stderr, "lwIP assertion \"%s\" %s:%d\n", x, __FILE__, __LINE__); fflush(stderr); abort(); } while (0)

#endif
