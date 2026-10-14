#!/bin/sh
# Builds the ffmpeg that a release carries, as build/ffmpeg, for Apple silicon.
# It has only the parts DillyDally asks for (see startPipeline in engine.swift) and no
# outside libraries, which keeps it under the LGPL. ./build.sh --release runs this
# when build/ffmpeg is missing. Needs Xcode's command-line tools and nothing else.
set -e
cd "$(dirname "$0")"

VERSION=9.0.2
SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
ARCHIVE="ffmpeg-$VERSION.tar.xz"

mkdir -p build
cd build
[ -f "$ARCHIVE" ] || curl -fL -o "$ARCHIVE" "https://ffmpeg.org/releases/$ARCHIVE"
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - > /dev/null

rm -rf source
mkdir source
tar -xf "$ARCHIVE" -C source --strip-components 1
(cd source
 ./configure --arch=arm64 --target-os=darwin --cc="clang -arch arm64" \
     --extra-cflags="-mmacosx-version-min=15.2" --extra-ldflags="-mmacosx-version-min=15.2" \
     --disable-everything --disable-autodetect --disable-doc --disable-debug --disable-network \
     --disable-ffplay --disable-ffprobe --enable-videotoolbox \
     --enable-protocol=pipe,file --enable-demuxer=rawvideo,pcm_f32le --enable-decoder=rawvideo,pcm_f32le \
     --enable-encoder=hevc_videotoolbox,h264_videotoolbox,aac --enable-muxer=mpegts \
     --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb \
     --enable-filter=volume,alimiter,aresample,aformat,anull,null,format,scale > /dev/null
 make -j"$(sysctl -n hw.ncpu)" ffmpeg > /dev/null)

cp source/ffmpeg ffmpeg
strip -x ffmpeg
cp source/COPYING.LGPLv2.1 ffmpeg-COPYING.LGPLv2.1
echo "Built build/ffmpeg ($VERSION)"
