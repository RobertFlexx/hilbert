#!/bin/sh
set -eu

HILBERT=${HILBERT:-./build/hilbert}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

find examples -type f -name '*.hil' -print | sort >"$tmp_dir/all"
checked=0
while IFS= read -r file; do
    if ! "$HILBERT" check "$file" -I stdlib -I bindings \
        --no-color --no-summary >"$tmp_dir/check.log" 2>&1; then
        echo "example check failed: $file" >&2
        cat "$tmp_dir/check.log" >&2
        exit 1
    fi
    checked=$((checked + 1))
done <"$tmp_dir/all"

# Flat examples and examples/small are dependency-free beyond the shipped
# stdlib. Binding examples are checked above but linked only by users who have
# the corresponding external C library installed.
find examples -maxdepth 1 -type f -name '*.hil' -print | sort >"$tmp_dir/runnable"
find examples/small -type f -name '*.hil' -print | sort >>"$tmp_dir/runnable"
ran=0
while IFS= read -r file; do
    name=$(basename "$file" .hil)
    binary="$tmp_dir/$name"
    if ! "$HILBERT" build "$file" -I stdlib -I bindings \
        --cache-dir "$tmp_dir/cache" -o "$binary" >"$tmp_dir/build.log" 2>&1; then
        echo "example native build failed: $file" >&2
        cat "$tmp_dir/build.log" >&2
        exit 1
    fi
    if ! python3 - "$binary" <<'PYRUN'
import subprocess
import sys

try:
    subprocess.run(
        [sys.argv[1]],
        check=True,
        timeout=10,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(f"example timed out: {sys.argv[1]}")
PYRUN
    then
        echo "example execution failed: $file" >&2
        exit 1
    fi
    ran=$((ran + 1))
done <"$tmp_dir/runnable"

echo "example tests ok: $checked checked, $ran native build/run"
