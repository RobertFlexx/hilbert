#!/bin/sh
set -eu

HILBERT=${HILBERT:-./build/hilbert}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

count=0
for source in stdlib/*.hil; do
    module=$(basename "$source" .hil)
    if ! "$HILBERT" build "$source" -I stdlib -I bindings \
        --cache-dir "$work/cache" -o "$work/$module" --quiet >"$work/output" 2>&1; then
        echo "native stdlib build failed: $source" >&2
        cat "$work/output" >&2
        exit 1
    fi
    count=$((count + 1))
done

printf '%s\n' "native stdlib test: $count modules linked"
