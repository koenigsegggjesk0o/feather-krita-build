#!/bin/bash
# Flutter SDK installer for the Feather-Krita automation box.
# (Recreated in loop-36 — box reset #2 wiped /home/z/flutter.)
# Version 3.35.3 = the CI arbitration pin (build-app.yml), so local
# analyze results match CI exactly (no 3.47-vs-3.35 drift).
set -e
V=3.35.3
TARBALL=/home/z/flutter_install/flutter_linux_${V}-stable.tar.xz
mkdir -p /home/z/flutter_install
if [ ! -f "$TARBALL" ]; then
  echo "downloading flutter $V ..."
  curl -sL --retry 5 --retry-delay 5 -C - \
    -o "$TARBALL" \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${V}-stable.tar.xz"
fi
echo "tarball size: $(stat -c %s "$TARBALL")"
if [ ! -d /home/z/flutter/bin ]; then
  mkdir -p /home/z
  tar xf "$TARBALL" -C /home/z/
fi
git config --global --add safe.directory /home/z/flutter || true
/home/z/flutter/bin/flutter --version
echo "FLUTTER INSTALL OK"
