#!/bin/sh
set -eu

stage=${1:?usage: install_tests.sh <staged-prefix-root>}
case "$stage" in
    /*) ;;
    *) stage=$(CDPATH= cd -- "$stage" && pwd) ;;
esac

test -x "$stage/usr/bin/hilbert"
test -x "$stage/usr/bin/hilmake"
test -x "$stage/usr/libexec/hilbert/hilbert"
test -f "$stage/usr/share/hilbert/stdlib/Raylib.hil"
test -f "$stage/usr/share/hilbert/stdlib/SQLite3.hil"
test -f "$stage/usr/share/hilbert/examples/README.md"
test -f "$stage/usr/share/hilbert/examples/bindings/sqlite_memory.hil"
grep -F 'HILBERT_HOME' "$stage/usr/bin/hilbert" >/dev/null

# Compile from outside the source checkout.  This proves that the relocatable
# launcher finds the installed runtime and stdlib instead of succeeding by
# accident through the repository's relative paths.
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$stage/usr/share/hilbert/examples/hello.hil" "$tmp_dir/hello.hil"
(
    cd "$tmp_dir"
    "$stage/usr/bin/hilbert" build hello.hil --cache-dir cache -o hello >/dev/null
    ./hello >output
    grep -F 'hello from Hilbert' output >/dev/null
    grep -Fx '42' output >/dev/null
)

echo 'install tests ok'
