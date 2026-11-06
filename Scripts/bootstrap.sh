#!/bin/zsh
# One-time setup for a fresh checkout: builds the two third-party pieces that are not stored in git.
#
#   Vendor/libjxl.xcframework            libjxl v0.12.0 (JPEG XL encoder), via Scripts/build-libjxl.sh
#   VideoChopChop/Helpers/ffmpeg         LGPL ffmpeg n8.1.3 helper (MKV/WebM import), via Scripts/build-ffmpeg.sh
#
# Both are built from pinned release tags, so the result is reproducible. Anything already built is
# skipped; pass --force to rebuild.
#
# Usage: Scripts/bootstrap.sh [--force]
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# --- prerequisites ---------------------------------------------------------------------------
missing=()
for tool in git cmake ninja clang xcodebuild lipo libtool codesign; do
    command -v "$tool" >/dev/null || missing+=("$tool")
done
# On an Intel Mac the native x86_64 ffmpeg build uses the nasm assembler (the cross build does not).
if [[ "$(uname -m)" == "x86_64" ]] && ! command -v nasm >/dev/null; then missing+=("nasm"); fi

if (( ${#missing} )); then
    echo "Missing tools: ${missing[*]}"
    echo "Install Xcode (with its command line tools) and, for the rest:  brew install cmake ninja nasm"
    exit 1
fi

# --- third-party libraries ---------------------------------------------------------------------
# Folders Xcode expects to exist (their contents are git-ignored).
mkdir -p Reference VideoChopChop/Helpers

if (( FORCE )) || [[ ! -d Vendor/libjxl.xcframework ]]; then
    echo "==> Building libjxl (a few minutes)"
    Scripts/build-libjxl.sh
else
    echo "==> libjxl already built (Vendor/libjxl.xcframework)"
fi

if (( FORCE )) || [[ ! -x VideoChopChop/Helpers/ffmpeg ]]; then
    echo "==> Building the ffmpeg helper (a few minutes)"
    Scripts/build-ffmpeg.sh
else
    echo "==> ffmpeg helper already built (VideoChopChop/Helpers/ffmpeg)"
fi

echo
echo "Done. Open VideoChopChop.xcodeproj in Xcode and build, or from the command line:"
echo "  xcodebuild build -project VideoChopChop.xcodeproj -scheme VideoChopChop -destination 'platform=macOS'"
