#!/usr/bin/env python3
"""5-loop-80 clean-host runtime closure gate.

Runs INSIDE a docker ubuntu:24.04 container that has ONLY the
desktop-stack libs any Linux desktop provides (X11/GL/fontconfig/
freetype/glib/...) — deliberately NO Qt5, NO KF5, NO exiv2/quazip/gsl/
lcms2/openexr/icu. Mounts: /bundle = the app bundle (libkrita_bridge.so
+ the full runtime closure), /fixture.kpp = a real PNG-container preset,
/gate.py = this file.

PASS criteria: the bridge dlopens with its ENTIRE DT_NEEDED chain
resolving from /bundle/lib ($ORIGIN RUNPATH — no system Qt/KF5), the
engine reports its version string, a context inits, a REAL preset loads
(KoStore ZIP + pigment/image/brush objects all come up) and the preset
name reads back.
"""
import ctypes
import sys

lib = ctypes.CDLL("/bundle/lib/libkrita_bridge.so")

lib.krita_brush_version.restype = ctypes.c_char_p
v = lib.krita_brush_version()
assert v and b"FeatherBridge-Krita" in v, v
print("container dlopen + version OK:", v.decode())

lib.krita_brush_init.restype = ctypes.c_void_p
h = lib.krita_brush_init()
assert h, "context init failed"

lib.krita_brush_load_preset.restype = ctypes.c_int
lib.krita_brush_load_preset.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.krita_brush_last_error.restype = ctypes.c_char_p
lib.krita_brush_last_error.argtypes = [ctypes.c_void_p]
rc = lib.krita_brush_load_preset(h, b"/fixture.kpp")
assert rc == 0, "load_preset rc=%s err=%s" % (rc, lib.krita_brush_last_error(h))

lib.krita_brush_get_preset_name.restype = ctypes.c_char_p
lib.krita_brush_get_preset_name.argtypes = [ctypes.c_void_p]
name = lib.krita_brush_get_preset_name(h)
assert name, "preset name empty"
print("container load_preset OK:", name.decode())

lib.krita_brush_destroy.argtypes = [ctypes.c_void_p]
lib.krita_brush_destroy(h)
print("CLEAN-HOST CLOSURE GATE: PASS")
sys.exit(0)
