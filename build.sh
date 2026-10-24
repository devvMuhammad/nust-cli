#!/bin/sh
# Builds release binaries for every platform into dist/, plus SHA256SUMS. Needs Zig 0.17 and,
# for the macOS targets, an installed macOS SDK (xcrun). Usage: ./build.sh [version]
set -e
cd "$(dirname "$0")"
VERSION=${1:-0.1.0}
SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
rm -rf dist && mkdir -p dist
build() { # zig-triple dist-name exe-name
  zig build -Dtarget="$1" -Doptimize=ReleaseSmall -Dversion="$VERSION" ${SDK:+-Dsdk="$SDK"} -p ".zig-out-$1"
  cp ".zig-out-$1/bin/$3" "dist/$2"
  rm -rf ".zig-out-$1"
  echo "built dist/$2"
}
build aarch64-macos   nust-darwin-arm64     nust
build x86_64-macos    nust-darwin-x64       nust
build x86_64-linux    nust-linux-x64        nust
build aarch64-linux   nust-linux-arm64      nust
build x86_64-windows  nust-windows-x64.exe  nust.exe
(cd dist && shasum -a 256 nust-* > SHA256SUMS)
