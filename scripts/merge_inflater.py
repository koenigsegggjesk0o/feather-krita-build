#!/usr/bin/env python3
"""Merge the hand-written DEFLATE inflater into the zlib-based bridge source
with conditional compilation: use system zlib when <zlib.h> is available
(gcc/Linux CI), otherwise fall back to the dependency-free Inflator (MSVC
Windows runners have no zlib). Resolves the two-agent race on this file."""
import re

CPP = 'native/krita_bridge/krita_bridge.cpp'
src = open(CPP).read()

# 1) Replace the plain #include <zlib.h> with a __has_include guard.
src = src.replace(
    '#include <zlib.h>',
    '''// Use the system zlib when available; otherwise the bundled RFC 1951
// inflater below covers .kpp payloads (MSVC runners ship no zlib).
#if defined(__has_include)
#  if __has_include(<zlib.h>)
#    define FEATHER_HAVE_ZLIB 1
#  endif
#endif

#ifdef FEATHER_HAVE_ZLIB
#include <zlib.h>
#endif''',
    1,
)

# 2) Wrap the zlib-based inflateRaw body and append the fallback inflater.
zlib_fn_start = src.index('// Inflate raw DEFLATE data using the system zlib')
zlib_fn_end = src.index('// Find the End-of-Central-Directory record.')
zlib_block = src[zlib_fn_start:zlib_fn_end]

fallback_block = open('/tmp/inflater-block.txt').read()

guarded = (
    '// Inflate raw DEFLATE data. Primary implementation uses the system\n'
    '// zlib when present; the portable fallback lives below.\n'
    '#ifdef FEATHER_HAVE_ZLIB\n'
    + zlib_block
    + '#else\n'
    + fallback_block
    + '\n#endif\n\n'
)

src = src[:zlib_fn_start] + guarded + src[zlib_fn_end:]

open(CPP, 'w').write(src)

# Sanity checks
assert '#ifdef FEATHER_HAVE_ZLIB' in src
assert 'struct Inflator' in src
assert src.count('QByteArray inflateRaw') == 2, 'both variants must exist'
print('merge OK:', len(src.splitlines()), 'lines')
