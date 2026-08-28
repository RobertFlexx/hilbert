#!/bin/sh
set -eu

detect_leaks=${ASAN_DETECT_LEAKS:-1}
flags='-std=c11 -O1 -g -pthread -fsanitize=address,undefined -fno-omit-frame-pointer'
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${SANITIZER_CC:-}" ]; then
    candidates=$SANITIZER_CC
else
    candidates="${CC:-cc} gcc-16"
fi
sanitizer_cc=
for candidate in $candidates; do
    if printf '%s\n' 'int main(void) { return 0; }' | \
        "$candidate" $flags -x c - -o "$tmp_dir/probe" >"$tmp_dir/probe.log" 2>&1; then
        sanitizer_cc=$candidate
        break
    fi
done

if [ -z "$sanitizer_cc" ]; then
    if [ "${REQUIRE_SANITIZERS:-0}" = 1 ]; then
        echo 'runtime sanitizer support is required but unavailable:' >&2
        cat "$tmp_dir/probe.log" >&2
        exit 1
    fi
    echo "runtime sanitizers: SKIP (none of '$candidates' can link ASan/UBSan on this host)"
    exit 0
fi

run_sanitized() {
    binary=$1
    log=$2
    if ASAN_OPTIONS=detect_leaks="$detect_leaks":halt_on_error=1 \
        UBSAN_OPTIONS=halt_on_error=1 "$binary" >"$log" 2>&1; then
        cat "$log"
        return 0
    fi
    if [ "$detect_leaks" = 1 ] && grep -q 'LeakSanitizer.*fatal\|does not work under ptrace' "$log"; then
        if [ "${REQUIRE_LEAK_SANITIZER:-0}" = 1 ]; then
            cat "$log" >&2
            return 1
        fi
        echo 'LeakSanitizer: SKIP (unavailable under this process sandbox); retrying ASan/UBSan without leak detection'
        ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
            UBSAN_OPTIONS=halt_on_error=1 "$binary"
        return
    fi
    cat "$log" >&2
    return 1
}

echo "runtime sanitizers: using $sanitizer_cc"
"$sanitizer_cc" $flags tests/runtime_gc.c runtime/hilbert_rt.c -o "$tmp_dir/runtime-gc-sanitize"
run_sanitized "$tmp_dir/runtime-gc-sanitize" "$tmp_dir/runtime-gc.log"
"$sanitizer_cc" $flags tests/runtime_gc_stress.c runtime/hilbert_rt.c -o "$tmp_dir/runtime-gc-stress-sanitize"
run_sanitized "$tmp_dir/runtime-gc-stress-sanitize" "$tmp_dir/runtime-gc-stress.log"

echo 'runtime sanitizers ok'
