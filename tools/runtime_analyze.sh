#!/bin/sh
set -eu

analysis_cc=${ANALYSIS_CC:-${CC:-cc}}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$analysis_cc" -std=c11 -pthread -Wall -Wextra -Werror -Wpedantic \
    -Wconversion -Wshadow -c runtime/hilbert_rt.c -o "$tmp_dir/runtime.o"

if "$analysis_cc" -std=c11 -pthread -Wall -Wextra -Werror -fanalyzer \
    -c runtime/hilbert_rt.c -o "$tmp_dir/runtime-analyzed.o" >"$tmp_dir/gcc.log" 2>&1; then
    echo 'runtime GCC analyzer ok'
else
    if grep -qi 'unrecognized.*fanalyzer\|unknown.*fanalyzer' "$tmp_dir/gcc.log"; then
        echo 'runtime GCC analyzer: SKIP (-fanalyzer unavailable)'
    else
        cat "$tmp_dir/gcc.log" >&2
        exit 1
    fi
fi

if command -v clang >/dev/null 2>&1; then
    clang --analyze -std=c11 -pthread -Wall -Wextra -Werror \
        runtime/hilbert_rt.c -o "$tmp_dir/runtime-clang.plist"
    echo 'runtime Clang analyzer ok'
else
    echo 'runtime Clang analyzer: SKIP (clang unavailable)'
fi

echo 'runtime static analysis ok'
