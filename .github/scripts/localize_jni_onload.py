#!/usr/bin/env python3
"""localize_jni_onload.py — 5-loop-66 corrected-approach-A hardening.

Demote every defined GLOBAL/WEAK `JNI_OnLoad` dynamic symbol in the staged
Android runtime .so files so ART's JNI_OnLoad search (System.loadLibrary)
can never land on a Qt/KF5 hook. Background (5-loop-61 evidence): the staged
libQt5Core_<abi>.so / libQt5AndroidExtras_<abi>.so export JNI_OnLoad hooks
that FindClass("org/qtproject/qt5/android/QtNative") — a class that does not
exist in a Flutter APK — so any BFS miss onto them returns JNI_ERR and kills
the app at load time. libkrita_bridge.so carries our OWN hook (JavaVM
capture + g_javaVm injection) and must keep it exported; it is skipped.

MECHANISM (why not objcopy): GNU objcopy --localize-symbol edits .symtab and
leaves .dynsym untouched (proven on binutils 2.44 — dlsym still resolves the
symbol), and LLVM objcopy semantics vary by version. Instead this tool
renames the symbol INSIDE .dynstr: 'JNI_OnLoad' -> 'XNI_OnLoad'. Same byte
length, so every ELF structure (section sizes, symbol offsets, hash tables)
stays valid. dlsym("JNI_OnLoad") can no longer match the name, while the
hash-chain layout is untouched (a lookup for the old name fails at the
string-compare step; suffix-merged neighbor names share bytes from offset 1
onward and are unaffected).

Usage: localize_jni_onload.py <dir-with-so> [<dir2> ...]
Skips libkrita_bridge.so. Idempotent (already-renamed files are no-ops).
Exits non-zero on any structural anomaly (never writes a half-understood file).
"""
import os
import struct
import sys

KEEP = {'libkrita_bridge.so'}
OLD = b'JNI_OnLoad\x00'
NEW_FIRST_BYTE = b'X'  # XNI_OnLoad — same length, never an existing API name

SHT_DYNSYM = 11
STB_GLOBAL, STB_WEAK = 1, 2


def fail(msg):
    print(f'  ERROR {msg}')
    sys.exit(1)


def patch(path):
    with open(path, 'rb') as f:
        buf = bytearray(f.read())

    if buf[:4] != b'\x7fELF':
        fail(f'{path}: not an ELF file')
    ei_class, ei_data = buf[4], buf[5]
    if ei_class != 2:
        fail(f'{path}: unsupported ELF class {ei_class} (need ELF64; Android NDK targets are 64-bit)')
    if ei_data != 1:
        fail(f'{path}: unsupported endianness {ei_data} (need little-endian)')

    e_shoff, = struct.unpack_from('<Q', buf, 0x28)
    e_shentsize, e_shnum = struct.unpack_from('<HH', buf, 0x3A)
    if e_shoff == 0 or e_shnum == 0:
        fail(f'{path}: no section headers (stripped section table?)')

    dynsyms = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_type, = struct.unpack_from('<I', buf, off + 4)     # sh_type
        sh_offset, sh_size = struct.unpack_from('<QQ', buf, off + 0x18)
        sh_link, = struct.unpack_from('<I', buf, off + 0x28)  # linked strtab
        if sh_type == SHT_DYNSYM:
            dynsyms.append((sh_offset, sh_size, sh_link))
    if not dynsyms:
        fail(f'{path}: no .dynsym section')

    patched = 0
    for sym_off, sym_size, strtab_idx in dynsyms:
        if strtab_idx >= e_shnum:
            fail(f'{path}: dynsym sh_link out of range')
        so = e_shoff + strtab_idx * e_shentsize
        str_off, str_size = struct.unpack_from('<QQ', buf, so + 0x18)
        dynstr = bytes(buf[str_off:str_off + str_size])

        n_entries = sym_size // 24  # Elf64_Sym
        for k in range(n_entries):
            base = sym_off + k * 24
            st_name, = struct.unpack_from('<I', buf, base)
            st_info = buf[base + 4]
            st_shndx, = struct.unpack_from('<H', buf, base + 6)
            bind = st_info >> 4
            if bind not in (STB_GLOBAL, STB_WEAK) or st_shndx == 0:
                continue  # UND imports and LOCALs are irrelevant
            if st_name + len(OLD) > len(dynstr):
                continue
            if dynstr[st_name:st_name + len(OLD)] != OLD:
                continue
            file_off = str_off + st_name
            if buf[file_off] != ord('J'):
                fail(f'{path}: dynstr byte mismatch at {file_off} — refusing to patch')
            buf[file_off] = ord(NEW_FIRST_BYTE)
            patched += 1

    if not patched:
        return False
    tmp = path + '.patched'
    with open(tmp, 'wb') as f:
        f.write(buf)
    os.replace(tmp, path)
    return True


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    changed = []
    for d in sys.argv[1:]:
        for name in sorted(os.listdir(d)):
            if not name.endswith('.so') or name in KEEP:
                continue
            p = os.path.join(d, name)
            if not os.path.isfile(p):
                continue
            did = patch(p)
            print(f'  {"JNI_OnLoad localized: " + name if did else "no exported JNI_OnLoad (untouched): " + name}')
            if did:
                changed.append(name)
    if changed:
        print(f'localized JNI_OnLoad in {len(changed)} staged lib(s): {", ".join(changed)}')
    else:
        print('no staged lib exported JNI_OnLoad — nothing to do')


if __name__ == '__main__':
    main()
