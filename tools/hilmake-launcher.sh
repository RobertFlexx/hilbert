#!/bin/sh
set -u

bindir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=$(CDPATH= cd -- "$bindir/.." && pwd)
: "${HILBERT_HOME:=$prefix/share/hilbert}"
export HILBERT_HOME
PATH="$bindir${PATH:+:$PATH}"
export PATH

tty_state=
if command -v stty >/dev/null 2>&1 && [ -r /dev/tty ]; then
    tty_state=$(stty -g </dev/tty 2>/dev/null || :)
fi

restore_tty() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$tty_state" ]; then
        stty "$tty_state" </dev/tty 2>/dev/null || :
    fi
    exit "$status"
}
trap restore_tty EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$prefix/libexec/hilbert/hilmake" "$@"
exit $?
