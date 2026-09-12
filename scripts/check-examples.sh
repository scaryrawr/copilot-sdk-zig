#!/bin/sh
set -eu

for example in examples/*; do
    if [ -f "$example/build.zig" ]; then
        zig build --build-file "$example/build.zig"
    fi
done
