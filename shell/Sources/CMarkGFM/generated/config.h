// Replaces CMake's output from src/config.h.in for clang on macOS.
#ifndef CMARK_CONFIG_H
#define CMARK_CONFIG_H

#include <stdbool.h>

#define HAVE_STDBOOL_H
#define HAVE___BUILTIN_EXPECT
#define HAVE___ATTRIBUTE__
#define CMARK_ATTRIBUTE(list) __attribute__(list)
#define CMARK_INLINE inline

#endif
