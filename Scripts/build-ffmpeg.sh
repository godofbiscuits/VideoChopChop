#!/bin/zsh
# Builds a minimal, LGPL-only ffmpeg command-line helper (arm64 + x86_64) used to convert
# containers AVFoundation can't read (Matroska/MKV, WebM) into MP4 on import.
#
# Output: VideoChopChop/Helpers/ffmpeg  (git-ignored; copied into the app bundle as a resource)
#
# The helper is signed with the sandbox "inherit" entitlement so the sandboxed app can launch it.
# Usage: Scripts/build-ffmpeg.sh        Requires: git, clang, make, Xcode command line tools.
set -euo pipefail

FFMPEG_TAG="n8.1.3"          # latest stable release
DEPLOYMENT_TARGET="27.3"
ARCHS=(arm64 x86_64)

ROOT="${0:A:h:h}"
WORK="$ROOT/Vendor/build-ffmpeg"     # git-ignored scratch space; downloaded source stays in its own directory
SRC="$WORK/ffmpeg-src"
OUT="$ROOT/VideoChopChop/Helpers/ffmpeg"
ENTITLEMENTS="$ROOT/Scripts/ffmpeg-helper.entitlements"

mkdir -p "$WORK" "${OUT:h}"

if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

JOBS=$(sysctl -n hw.ncpu)
for ARCH in $ARCHS; do
    BUILD="$WORK/build-$ARCH"
    mkdir -p "$BUILD"
    cd "$BUILD"

    EXTRA=()
    if [[ "$ARCH" != "$(uname -m)" ]]; then
        # Cross-compiling for the other architecture: no assembler (nasm) needed.
        EXTRA=(--enable-cross-compile --target-os=darwin --disable-x86asm)
    fi

    "$SRC/configure" \
        --arch="$ARCH" --cc="clang -arch $ARCH" $EXTRA \
        --extra-cflags="-mmacosx-version-min=$DEPLOYMENT_TARGET" \
        --extra-ldflags="-mmacosx-version-min=$DEPLOYMENT_TARGET" \
        --disable-everything --disable-autodetect --disable-doc --disable-debug \
        --disable-network --disable-ffplay --disable-ffprobe --enable-ffmpeg \
        --disable-gpl --disable-nonfree --disable-version3 \
        --enable-videotoolbox --enable-audiotoolbox \
        --enable-protocol=file,pipe \
        --enable-demuxer=matroska,mov,avi,mpegts \
        --enable-muxer=mp4,mov \
        --enable-parser=h264,hevc,av1,vp9,aac,ac3,opus,vorbis,flac,mpegaudio,mpeg4video,mpegvideo \
        --enable-decoder=h264,hevc,vp8,vp9,mpeg4,mpeg2video,aac,ac3,eac3,opus,vorbis,flac,mp3,mp3float,dca,truehd,mlp,pcm_s16le,pcm_s24le,pcm_s32le \
        --enable-encoder=aac,hevc_videotoolbox,h264_videotoolbox \
        --enable-bsf=aac_adtstoasc,extract_extradata,vp9_superframe,null \
        --enable-filter=scale,format,aresample,aformat,anull,null,fps

    make -j"$JOBS" ffmpeg
done

lipo -create "$WORK"/build-*/ffmpeg -output "$OUT"
chmod +x "$OUT"
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$OUT"

echo "Built $OUT"
file "$OUT"
"$OUT" -hide_banner -version | head -3
