#!/bin/sh
set -eu

HILBERT=${HILBERT:-./build/hilbert}
HILMAKE=${HILMAKE:-./build/hilmake}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$HILBERT" | grep -F 'compiler for the Hilbert language' >/dev/null
"$HILBERT" --version | grep -F 'Hilbert 1.0.0' >/dev/null
"$HILBERT" --help | grep -F 'commands:' >/dev/null
"$HILBERT" version | grep -F 'Hilbert 1.0.0' >/dev/null
"$HILBERT" targets | grep -F 'x86_64-linux-gnu' >/dev/null
"$HILMAKE" | grep -F 'project builder for Hilbert' >/dev/null
"$HILMAKE" --version | grep -F 'hilmake 1.0.0' >/dev/null
"$HILMAKE" --help | grep -F 'commands:' >/dev/null
"$HILMAKE" version | grep -F 'hilmake 1.0.0' >/dev/null

if "$HILBERT" --definitely-invalid --no-color >"$tmp_dir/error" 2>&1; then
    echo 'unknown compiler option unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'H2101' "$tmp_dir/error" >/dev/null


# Diagnostics belong on stderr.  In automatic mode redirected stderr must not
# contain ANSI escapes, while stdout remains available for normal command data.
if "$HILBERT" --definitely-invalid >"$tmp_dir/invalid-stdout" 2>"$tmp_dir/invalid-stderr"; then
    echo 'unknown compiler option unexpectedly succeeded' >&2
    exit 1
fi
test ! -s "$tmp_dir/invalid-stdout"
grep -F 'H2101' "$tmp_dir/invalid-stderr" >/dev/null
if LC_ALL=C grep "$(printf '\033')" "$tmp_dir/invalid-stderr" >/dev/null; then
    echo 'automatic diagnostic color leaked ANSI escapes into redirected stderr' >&2
    exit 1
fi

long_arg=$(python3 - <<'PYARG'
print('x' * 1100)
PYARG
)
if "$HILBERT" "$long_arg" --no-color >"$tmp_dir/long-arg-out" 2>"$tmp_dir/long-arg-err"; then
    echo 'compiler accepted an oversized command-line argument' >&2
    exit 1
fi
grep -F 'H2106' "$tmp_dir/long-arg-err" >/dev/null

if "$HILBERT" check tests/smoke.hil --error-limit 4294967297 --no-color >"$tmp_dir/card-overflow" 2>&1; then
    echo 'compiler accepted a CARDINAL-overflowing option value' >&2
    exit 1
fi
grep -F 'invalid --error-limit value' "$tmp_dir/card-overflow" >/dev/null

# Artifact-producing commands must discover and type-check imports too.  These
# used to work only for self-contained roots even though normal builds worked.
"$HILBERT" dump-ast tests/smoke.hil --no-color >"$tmp_dir/ast"
grep -F 'Smoke' "$tmp_dir/ast" >/dev/null
"$HILBERT" dump-hir tests/import_values.hil -I tests \
    --cache-dir "$tmp_dir/cache" --no-color >"$tmp_dir/hir"
# Imported constants fold into their literal HIR value.  The mutable export
# remains a useful check that dump-hir loaded and lowered the dependency.
grep -F 'ImportValuesDep__Mutable' "$tmp_dir/hir" >/dev/null
"$HILBERT" emit-asm tests/import_values.hil -I tests \
    --cache-dir "$tmp_dir/cache" -o "$tmp_dir/import-values.s" >/dev/null
test -s "$tmp_dir/import-values.s"
"$HILBERT" emit-obj tests/import_values.hil -I tests \
    --cache-dir "$tmp_dir/cache" -o "$tmp_dir/import-values.o" >/dev/null
test -s "$tmp_dir/import-values.o"

echo 'cli tests ok'
