#!/bin/sh
# Runs the unit tests and prints each test name. `zig build test` does the same, quietly.
cd "$(dirname "$0")" || exit 1
zig build test --summary all >/dev/null 2>&1
opts=$(ls -t .zig-cache/o/*/options.zig | head -1)
extra=""
[ "$(uname)" = Darwin ] && extra="-framework Security -framework CoreFoundation -lc"
exec zig test --dep build_options -Mroot=src/main.zig -Mbuild_options="$opts" $extra "$@"
