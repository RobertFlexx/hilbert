#!/bin/sh
set -eu

HILBERT=${HILBERT:-./build/hilbert}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_order() {
    order=$1
    cache="$work/cache-$order"
    if [ "$order" = main-first ]; then
        "$HILBERT" build tests/ImportValuesDep.hil -I tests --cache-dir "$cache" -o "$work/dep-main" --quiet
        "$HILBERT" build tests/import_values.hil -I tests --cache-dir "$cache" -o "$work/import-main" --quiet
    else
        "$HILBERT" build tests/import_values.hil -I tests --cache-dir "$cache" -o "$work/import-main" --quiet
        "$HILBERT" build tests/ImportValuesDep.hil -I tests --cache-dir "$cache" -o "$work/dep-main" --quiet
    fi
    "$work/dep-main"
    "$work/import-main"
    set -- "$cache"/ImportValuesDep.*.main.O2.o
    test -f "$1"
    set -- "$cache"/ImportValuesDep.*.module.O2.o
    test -f "$1"
}

run_order main-first
run_order module-first

link_cache="$work/link-cache"
link_output="$work/link-output"
"$HILBERT" build tests/import_values.hil -I tests --cache-dir "$link_cache" -o "$link_output" --quiet
"$HILBERT" build tests/import_values.hil -I tests --cache-dir "$link_cache" -o "$link_output" >"$work/noop"
grep -F 'hilbert: up to date' "$work/noop" >/dev/null

# A changed link command must invalidate the stamp even when every object is
# reusable. Strip is harmless here and gives us a setting with visible output.
"$HILBERT" build tests/import_values.hil -I tests --cache-dir "$link_cache" -o "$link_output" --strip >"$work/relink"
grep -F 'hilbert: linked' "$work/relink" >/dev/null

# Touching/replacing an output after its stamp is suspicious. Relink instead of
# accepting an executable the compiler did not produce after that stamp.
touch "$link_output"
"$HILBERT" build tests/import_values.hil -I tests --cache-dir "$link_cache" -o "$link_output" --strip >"$work/replaced"
grep -F 'hilbert: linked' "$work/replaced" >/dev/null

runtime_cache="$work/runtime-cache"
"$HILBERT" build tests/native_thread_callback.hil --cache-dir "$runtime_cache" -O0 -o "$work/thread-o0" --quiet
"$HILBERT" build tests/native_thread_callback.hil --cache-dir "$runtime_cache" -O3 -o "$work/thread-o3" --quiet
test -f "$runtime_cache/hilbert_rt.v4.x86_64-linux-gnu.O0.o"
test -f "$runtime_cache/hilbert_rt.v4.x86_64-linux-gnu.O3.o"

context_cache="$work/context-cache"
"$HILBERT" build tests/smoke.hil --cache-dir "$context_cache" --profile debug -O0 -o "$work/context-debug" --quiet
"$HILBERT" build tests/smoke.hil --cache-dir "$context_cache" --profile release -O0 -o "$work/context-release" --quiet
set -- "$context_cache"/Smoke.*.debug.hosted.main.O0.g.o
test -f "$1"
set -- "$context_cache"/Smoke.*.release.hosted.main.O0.o
test -f "$1"

printf '%s\n' 'incremental object roles, context keys, fingerprints and link stamps: ok'
