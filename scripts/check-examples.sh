#!/bin/sh
set -eu

if grep -R -n -E 'catch[[:space:]]*\{\}|catch[[:space:]]+break' examples README.md; then
    echo "examples must report failures instead of discarding them" >&2
    exit 1
fi

if grep -R -n '@constCast' src examples README.md |
    grep -v '^src/session_event_generated\.zig:' |
    grep -v '^src/[^:]*:[0-9][0-9]*:    @memset(@constCast(value), 0);'; then
    echo "@constCast is forbidden outside generated event code and secret wiping" >&2
    exit 1
fi

for example in examples/*; do
    if [ -f "$example/build.zig" ]; then
        zig build --build-file "$example/build.zig"
    fi
done
