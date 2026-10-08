#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=42494999e6492aaab9c1db785ecd293ef10b3aed
checksum=0d5c7d5c6ac3b4df83cdaa3c2494a7bfa340a0f3ac4fec82b863ba8fd33e5044
if [ -f .build/native/.portal-revision ] && [ "$(cat .build/native/.portal-revision)" = "$revision-auth-transport-v14" ]; then exit 0; fi
rm -rf .build/native .build/native-build .build/jpeg-build
command -v cmake >/dev/null || { echo 'Install build dependencies: brew install cmake'; exit 1; }
prefix="$(brew --prefix)"
mkdir -p .build/downloads
native="$PWD/.build/native"
export MACOSX_DEPLOYMENT_TARGET=14.0
# Bundled libraries are built from source so they run on the app's minimum macOS, not the build machine's.
fetch() {
  curl --fail --location --retry 3 "$1" -o ".build/downloads/$3.tar.gz"
  echo "$2  .build/downloads/$3.tar.gz" | shasum -a 256 -c -
  rm -rf ".build/downloads/$3"
  tar -xzf ".build/downloads/$3.tar.gz" -C .build/downloads
}
fetch https://github.com/openssl/openssl/releases/download/openssl-3.6.5/openssl-3.6.5.tar.gz a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98 openssl-3.6.5
(cd .build/downloads/openssl-3.6.5 && ./Configure "darwin64-$(uname -m)-cc" --prefix="$native" --libdir=lib shared no-tests no-docs && make -j"$(sysctl -n hw.ncpu)" && make install_sw)
fetch https://ftpmirror.gnu.org/nettle/nettle-4.0.tar.gz 3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094 nettle-4.0
(cd .build/downloads/nettle-4.0 && ./configure --prefix="$native" --libdir="$native/lib" --disable-public-key --disable-documentation --disable-static && make -j"$(sysctl -n hw.ncpu)" && make install)
fetch https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz 6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e libjpeg-turbo-3.2.0
cmake -S .build/downloads/libjpeg-turbo-3.2.0 -B .build/jpeg-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$native" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DENABLE_STATIC=OFF
cmake --build .build/jpeg-build --parallel
cmake --install .build/jpeg-build
fetch https://www.oberhumer.com/opensource/lzo/download/lzo-2.10.tar.gz c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072 lzo-2.10
(cd .build/downloads/lzo-2.10 && ./configure --prefix="$native" --enable-shared --disable-static && make -j"$(sysctl -n hw.ncpu)" && make install)
archive=.build/downloads/libvnc.tar.gz
curl --fail --location --retry 3 "https://codeload.github.com/LibVNC/libvncserver/tar.gz/$revision" -o "$archive"
echo "$checksum  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C .build/downloads
source_dir=".build/downloads/libvncserver-$revision"
python3 scripts/patch-vnc.py "$source_dir/src/libvncclient/rfbclient.c"
cmake -S "$source_dir" -B .build/native-build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/.build/native" \
  -DCMAKE_PREFIX_PATH="$native;$prefix" -DOPENSSL_ROOT_DIR="$native" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DWITH_LIBVNCSERVER=OFF -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF \
  -DWITH_GNUTLS=OFF -DWITH_GCRYPT=OFF -DWITH_OPENSSL=ON \
  -DWITH_SASL=ON -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_QT=OFF \
  -DWITH_FFMPEG=OFF -DWITH_XCB=OFF -DBUILD_SHARED_LIBS=ON
cmake --build .build/native-build --parallel
cmake --install .build/native-build
printf '%s' "$revision-auth-transport-v14" > .build/native/.portal-revision
