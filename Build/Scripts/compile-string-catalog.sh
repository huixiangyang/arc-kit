#!/bin/sh
# 每个 target 一次产出完整 lproj，删除旧复数表和已移除语言，避免增量构建残留。
set -eu
output="$1"
shift
test -n "$output" && test "$output" != /
rm -rf "$output"
mkdir -p "$output"
for catalog in "$@"; do
    /usr/bin/xcrun xcstringstool compile "$catalog" --output-directory "$output"
done
