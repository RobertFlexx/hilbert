#!/bin/sh
set -eu

prefix=/usr/local
destdir=
jobs=1
run_tests=1

usage() {
    cat <<'USAGE'
usage: ./install.sh [options]

  --user              install below ~/.local
  --prefix DIR        installation prefix (default /usr/local)
  --destdir DIR       stage the install below DIR
  --jobs N            parallel make jobs
  --no-test           skip repository/runtime/CLI checks
  -h, --help          show this help
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --user) prefix=${HOME:?}/.local ;;
        --prefix)
            [ "$#" -ge 2 ] || { echo 'install: --prefix needs a directory' >&2; exit 2; }
            prefix=$2; shift ;;
        --destdir)
            [ "$#" -ge 2 ] || { echo 'install: --destdir needs a directory' >&2; exit 2; }
            destdir=$2; shift ;;
        --jobs)
            [ "$#" -ge 2 ] || { echo 'install: --jobs needs a positive integer' >&2; exit 2; }
            jobs=$2; shift
            case "$jobs" in ''|*[!0-9]*|0) echo 'install: --jobs needs a positive integer' >&2; exit 2 ;; esac ;;
        --no-test) run_tests=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for tool in gm2 make cc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "install: required tool not found: $tool" >&2
        exit 1
    fi
done
if [ "$run_tests" -eq 1 ] && ! command -v python3 >/dev/null 2>&1; then
    echo "install: python3 is required for the release checks (or use --no-test)" >&2
    exit 1
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"

printf '%s\n' "building Hilbert with $jobs job(s)"
make -j"$jobs"

if [ "$run_tests" -eq 1 ]; then
    make check
    make cli-test
fi

make install PREFIX="$prefix" DESTDIR="$destdir"
printf '%s\n' "installed Hilbert under ${destdir}${prefix}"
