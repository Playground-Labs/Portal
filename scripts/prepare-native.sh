#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=42494999e6492aaab9c1db785ecd293ef10b3aed
checksum=0d5c7d5c6ac3b4df83cdaa3c2494a7bfa340a0f3ac4fec82b863ba8fd33e5044
if [ -f .build/native/.portal-revision ] && [ "$(cat .build/native/.portal-revision)" = "$revision-auth-transport-v9" ]; then exit 0; fi
command -v cmake >/dev/null || { echo 'Install build dependencies: brew install cmake openssl jpeg-turbo nettle'; exit 1; }
prefix="$(brew --prefix)"
mkdir -p .build/downloads
archive=.build/downloads/libvnc.tar.gz
curl --fail --location --retry 3 "https://codeload.github.com/LibVNC/libvncserver/tar.gz/$revision" -o "$archive"
echo "$checksum  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C .build/downloads
source_dir=".build/downloads/libvncserver-$revision"
python3 scripts/patch-vnc.py "$source_dir/src/libvncclient/rfbclient.c"
cmake -S "$source_dir" -B .build/native-build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/.build/native" \
  -DCMAKE_PREFIX_PATH="$prefix" -DOPENSSL_ROOT_DIR="$(brew --prefix openssl)" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DWITH_LIBVNCSERVER=OFF -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF \
  -DWITH_GNUTLS=OFF -DWITH_GCRYPT=OFF -DWITH_OPENSSL=ON \
  -DWITH_SASL=ON -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_QT=OFF \
  -DWITH_FFMPEG=OFF -DWITH_XCB=OFF -DBUILD_SHARED_LIBS=ON
cmake --build .build/native-build --parallel
cmake --install .build/native-build
printf '%s' "$revision-auth-transport-v9" > .build/native/.portal-revision
