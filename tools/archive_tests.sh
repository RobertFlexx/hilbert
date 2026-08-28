#!/bin/sh
set -eu

archive=${1:?usage: archive_tests.sh <archive.tar.gz>}
version=$(cat VERSION)
top="hilbert-$version"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

tar -tzf "$archive" >"$tmp_dir/list"
if grep -Ev "^$top(/|$)" "$tmp_dir/list" >"$tmp_dir/outside"; then
    echo "archive has members outside $top:" >&2
    cat "$tmp_dir/outside" >&2
    exit 1
fi
for required in README.md VERSION Makefile compiler/hilbert.mod runtime/hilbert_rt.c docs/RELEASE.md; do
    grep -Fx "$top/$required" "$tmp_dir/list" >/dev/null || {
        echo "archive is missing $required" >&2
        exit 1
    }
done
if grep -E "^$top/(build|dist|\.git)(/|$)|/__pycache__/|\.(py[co]|plist)$" "$tmp_dir/list" >/dev/null; then
    echo 'archive contains generated or local metadata' >&2
    exit 1
fi

tar -xzf "$archive" -C "$tmp_dir"
(
    cd "$tmp_dir/$top"
    python3 tools/repo_check.py
    python3 tools/binding_check.py
    make -j2 all
    ./build/hilbert --version | grep -F 'Hilbert 1.0.0' >/dev/null
    ./build/hilbert build examples/hello.hil -o build/archive-hello >/dev/null
    ./build/archive-hello >build/archive-output
    grep -F 'hello from Hilbert' build/archive-output >/dev/null
)

echo 'release archive tests ok'
