#!/usr/bin/env python3
"""Decode bisect residual streams with ffmpeg and verify the luma pixels
match the source gradient closely (proves block-index placement, not just
bitstream parseability)."""
import subprocess, sys, os

os.chdir('/home/z/fkr-step1/scripts/out')

def decode_luma(name, w, h):
    p = subprocess.run(
        ['ffmpeg', '-v', 'error', '-i', f'bisect_{name}.h264',
         '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
        capture_output=True)
    assert p.returncode == 0 and len(p.stdout) >= w * h, (name, p.stderr[:200])
    return p.stdout[:w * h]

def gradient(w, h, base=128, amp=40):
    return bytes(min(255, max(0, base + (amp * (x + y)) // (w + h)))
                 for y in range(h) for x in range(w))

failures = 0
# (name, w, h, amp) — g10/g20 use weaker gradients than the default 40.
for name, w, h, amp in [('v11_diag32', 32, 32, 40), ('g10', 32, 32, 10),
                        ('g20', 32, 32, 20), ('g40', 32, 32, 40),
                        ('v14_fullstack', 16, 32, 40), ('q26', 32, 32, 40)]:
    src = gradient(w, h, amp=amp)
    dec = decode_luma(name, w, h)
    errs = [abs(a - b) for a, b in zip(src, dec)]
    mean = sum(errs) / len(errs)
    mx = max(errs)
    # A scrambled block order produces errors ~40-90; a correct one stays
    # within quantization + reconstruction tolerance (<= ~30).
    ok = mx <= 30
    print(f'{name}: mean_err={mean:.2f} max_err={mx} -> {"OK" if ok else "SCRAMBLED?"}')
    if not ok:
        failures += 1
sys.exit(1 if failures else 0)
