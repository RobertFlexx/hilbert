#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

: "${MAKE:=make}"
: "${GM2:=gm2}"

if ! command -v "$GM2" >/dev/null 2>&1; then
    printf '%s\n' "bootstrap: GNU Modula-2 not found: $GM2" >&2
    exit 1
fi

"$MAKE" GM2="$GM2" compiler
cp build/hilbert build/hilbert0
printf '%s\n' "bootstrap: built $root/build/hilbert0"
