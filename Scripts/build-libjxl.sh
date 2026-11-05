#!/bin/zsh
# Builds libjxl (encoder only is used) as static libraries for arm64 + x86_64 macOS
# and packages them as Vendor/libjxl.xcframework.
#
# Usage: Scripts/build-libjxl.sh
# Requires: git, cmake, ninja, Xcode command line tools.
set -euo pipefail

LIBJXL_TAG="v0.12.0"   # latest stable release
DEPLOYMENT_TARGET="27.3"
ARCHS=(arm64 x86_64)

ROOT="${0:A:h:h}"
WORK="$ROOT/Vendor/build"          # git-ignored scratch space
SRC="$WORK/libjxl-src"             # downloaded source lives in its own directory
OUT="$ROOT/Vendor/libjxl.xcframework"

mkdir -p "$WORK"

if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 --branch "$LIBJXL_TAG" --recursive --shallow-submodules \
        https://github.com/libjxl/libjxl.git "$SRC"
fi

for ARCH in $ARCHS; do
    BUILD="$WORK/build-$ARCH"
    cmake -S "$SRC" -B "$BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DJPEGXL_ENABLE_TOOLS=OFF \
        -DJPEGXL_ENABLE_BENCHMARK=OFF \
        -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_DOXYGEN=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF \
        -DJPEGXL_ENABLE_JNI=OFF \
        -DJPEGXL_ENABLE_PLUGINS=OFF \
        -DJPEGXL_ENABLE_VIEWERS=OFF \
        -DJPEGXL_ENABLE_FUZZERS=OFF \
        -DJPEGXL_ENABLE_SJPEG=OFF \
        -DJPEGXL_ENABLE_OPENEXR=OFF \
        -DJPEGXL_ENABLE_SKCMS=ON \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF \
        -DJPEGXL_FORCE_SYSTEM_HWY=OFF
    cmake --build "$BUILD" --target jxl_dec jxl jxl_threads jxl_cms

    # Merge every static archive we need into one library per architecture.
    LIBS=(
        "$BUILD/lib/libjxl.a"
        "$BUILD/lib/libjxl_cms.a"
        "$BUILD/lib/libjxl_threads.a"
    )
    LIBS+=("${(@f)$(find "$BUILD/third_party" -name 'libhwy.a' -o -name 'libbrotli*.a')}")
    libtool -static -o "$WORK/libjxl_all-$ARCH.a" $LIBS
done

lipo -create "$WORK"/libjxl_all-*.a -output "$WORK/libjxl_all.a"

# Headers: public headers plus the generated ones from the build directory.
HEADERS="$WORK/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS/jxl"
cp "$SRC"/lib/include/jxl/*.h "$HEADERS/jxl/"
cp "$WORK/build-${ARCHS[1]}"/lib/include/jxl/*.h "$HEADERS/jxl/"

cat > "$HEADERS/jxl_all.h" <<'EOF'
#include <jxl/types.h>
#include <jxl/codestream_header.h>
#include <jxl/color_encoding.h>
#include <jxl/encode.h>
#include <jxl/version.h>
EOF

cat > "$HEADERS/module.modulemap" <<'EOF'
module CJXL {
    header "jxl_all.h"
    link "c++"
    export *
}
EOF

rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$WORK/libjxl_all.a" -headers "$HEADERS" \
    -output "$OUT"

echo "Built $OUT"
