#!/bin/sh
set -eu

HILMAKE=${HILMAKE:-./build/hilmake}
PATH_TO_ADD=$(CDPATH= cd -- "$(dirname -- "$HILMAKE")" && pwd)
export PATH="$PATH_TO_ADD:$PATH"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$HILMAKE" show -f tests/Hilbertfile.test >"$tmp_dir/show"
grep -F 'project HilmakeTest' "$tmp_dir/show" >/dev/null
"$HILMAKE" info -f tests/Hilbertfile.test >"$tmp_dir/info"
grep -F 'project: hilmake-test' "$tmp_dir/info" >/dev/null
grep -F 'version: 1.0.0' "$tmp_dir/info" >/dev/null
"$HILMAKE" info -f tests/Hilbertfile.info-only >"$tmp_dir/info-only"
grep -F 'project: info-only' "$tmp_dir/info-only" >/dev/null
"$HILMAKE" build --help >"$tmp_dir/build-help"
grep -F 'usage: hilmake build' "$tmp_dir/build-help" >/dev/null
"$HILMAKE" targets >"$tmp_dir/targets"
grep -F 'x86_64-linux-gnu' "$tmp_dir/targets" >/dev/null
"$HILMAKE" graph -f tests/Hilbertfile.division --no-color >"$tmp_dir/graph"
grep -F 'DivisionImport' "$tmp_dir/graph" >/dev/null
grep -F -- '-> DivisionLibrary' "$tmp_dir/graph" >/dev/null
"$HILMAKE" graph -f tests/Hilbertfile.division --dot --no-color >"$tmp_dir/graph-dot"
grep -F '"DivisionImport" -> "DivisionLibrary"' "$tmp_dir/graph-dot" >/dev/null
"$HILMAKE" check -f tests/Hilbertfile.test --no-color >/dev/null
"$HILMAKE" build -f tests/Hilbertfile.test --no-color >/dev/null
test -x build/hilmake-test
"$HILMAKE" run -f tests/Hilbertfile.test --no-color >/dev/null
"$HILMAKE" build -f tests/Hilbertfile.run-args --no-color >/dev/null
"$HILMAKE" build -f tests/Hilbertfile.run-args --no-color >"$tmp_dir/noop-spaces"
grep -F 'hilbert: up to date' "$tmp_dir/noop-spaces" >/dev/null
"$HILMAKE" run -f tests/Hilbertfile.run-args --no-color -- "space arg" "apostrophe's" >/dev/null
"$HILMAKE" clean -f tests/Hilbertfile.run-args --no-color >/dev/null
"$HILMAKE" rebuild -f tests/Hilbertfile.test --no-color >/dev/null
test -x build/hilmake-test
"$HILMAKE" clean -f tests/Hilbertfile.test --no-color >/dev/null
test ! -e build/hilmake-test
test ! -e build/.hilmake-test-cache

if "$HILMAKE" clean -f tests/Hilbertfile.unsafe --no-color >"$tmp_dir/unsafe" 2>&1; then
    echo 'hilmake accepted an unsafe clean path' >&2
    exit 1
fi
grep -F 'refusing to remove unsafe BUILD_DIR' "$tmp_dir/unsafe" >/dev/null

if "$HILMAKE" buid >"$tmp_dir/typo" 2>&1; then
    echo 'hilmake accepted an unknown command' >&2
    exit 1
fi
grep -F "unknown command 'buid'" "$tmp_dir/typo" >/dev/null
grep -F "did you mean 'build'?" "$tmp_dir/typo" >/dev/null

if "$HILMAKE" --definitely-invalid >"$tmp_dir/unknown" 2>&1; then
    echo 'hilmake accepted an unknown option' >&2
    exit 1
fi
grep -F 'unknown option or argument' "$tmp_dir/unknown" >/dev/null

if "$HILMAKE" show -f tests/Hilbertfile.test -j4294967297 --no-color >"$tmp_dir/card-overflow" 2>&1; then
    echo 'hilmake accepted a CARDINAL-overflowing jobs value' >&2
    exit 1
fi
grep -F 'jobs must be between 1 and 8' "$tmp_dir/card-overflow" >/dev/null


long_arg=$(python3 - <<'PYARG'
print('x' * 1100)
PYARG
)
if "$HILMAKE" "$long_arg" --no-color >"$tmp_dir/long-arg" 2>&1; then
    echo 'hilmake accepted an oversized command-line argument' >&2
    exit 1
fi
grep -F 'H2106' "$tmp_dir/long-arg" >/dev/null

# A generated compiler command larger than the internal command buffer must
# fail before system(3), never execute a truncated shell command.
overflow_file="$tmp_dir/Hilbertfile.command-overflow"
python3 - "$overflow_file" <<'PYOVERFLOW'
from pathlib import Path
import sys
p = Path(sys.argv[1])
path = 'p' * 600
lines = [
    'PROJECT CommandOverflow;',
    'ROOT "tests/smoke.hil";',
    'OUTPUT "build/command-overflow";',
    'BUILD_DIR "build/.command-overflow";',
]
for i in range(60):
    lines.append(f'MODULE_PATH "{path}{i:02d}";')
lines.append('END CommandOverflow.')
p.write_text('\n'.join(lines) + '\n')
PYOVERFLOW
if "$HILMAKE" check -f "$overflow_file" --no-color >"$tmp_dir/command-overflow" 2>&1; then
    echo 'hilmake executed an oversized generated command' >&2
    exit 1
fi
grep -F 'H2018' "$tmp_dir/command-overflow" >/dev/null

if "$HILMAKE" build -f tests/Hilbertfile.missing --no-color >"$tmp_dir/missing" 2>&1; then
    echo 'hilmake lost the compiler child failure status' >&2
    exit 1
fi
grep -F 'cannot open source file' "$tmp_dir/missing" >/dev/null

"$HILMAKE" build -f tests/Hilbertfile.exit-status --no-color >/dev/null
set +e
"$HILMAKE" run -f tests/Hilbertfile.exit-status --no-color >/dev/null 2>&1
exit_status=$?
set -e
test "$exit_status" -eq 7

"$HILMAKE" build -f tests/Hilbertfile.signal --no-color >/dev/null
python3 - "$HILMAKE" <<'PYRUN'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

process = subprocess.Popen(
    [sys.argv[1], "run", "-f", "tests/Hilbertfile.signal", "--no-color"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
deadline = time.monotonic() + 5
expected = Path("build/hilmake-signal").resolve()
while time.monotonic() < deadline:
    try:
        if Path(f"/proc/{process.pid}/exe").resolve() == expected:
            break
    except FileNotFoundError:
        pass
    time.sleep(0.01)
else:
    process.kill()
    raise SystemExit("hilmake run did not exec the project output")

os.kill(process.pid, signal.SIGINT)
if process.wait(timeout=5) != -signal.SIGINT:
    raise SystemExit("project did not preserve normal SIGINT behavior")
PYRUN

"$HILMAKE" clean -f tests/Hilbertfile.division --no-color >/dev/null 2>&1 || true
"$HILMAKE" build -f tests/Hilbertfile.division -j2 --trace --no-color >"$tmp_dir/parallel"
grep -F 'parallel native batch 2' "$tmp_dir/parallel" >/dev/null
"$HILMAKE" build -f tests/Hilbertfile.division -q --no-color >"$tmp_dir/quiet"
test ! -s "$tmp_dir/quiet"

install_prefix="$tmp_dir/prefix with apostrophe's"
"$HILMAKE" install -f tests/Hilbertfile.test --prefix "$install_prefix" --no-color >/dev/null
test -x "$install_prefix/bin/hilmake-test"
"$HILMAKE" clean -f tests/Hilbertfile.test --no-color >/dev/null
"$HILMAKE" uninstall -f tests/Hilbertfile.test --prefix "$install_prefix" --no-color >/dev/null
test ! -e "$install_prefix/bin/hilmake-test"

if "$HILMAKE" install -f tests/Hilbertfile.install-unsafe --prefix "$tmp_dir/safe-prefix" --no-color >"$tmp_dir/install-unsafe" 2>&1; then
    echo 'hilmake accepted an INSTALL_DIR that escapes the prefix' >&2
    exit 1
fi
grep -F 'INSTALL_DIR must be a relative path without ..' "$tmp_dir/install-unsafe" >/dev/null
test ! -e "$tmp_dir/escaped/hilmake-install-unsafe"

manifest_prefix="$tmp_dir/manifest-prefix"
"$HILMAKE" install -f tests/Hilbertfile.test --prefix "$manifest_prefix" --no-color >/dev/null
manifest_file=$(find "$manifest_prefix/share/hilmake" -type f -name '*.manifest' -print -quit)
test -n "$manifest_file"
printf '%s\n%s\n' 'DifferentProject' "$manifest_prefix/bin/hilmake-test" >"$manifest_file"
if "$HILMAKE" uninstall -f tests/Hilbertfile.test --prefix "$manifest_prefix" --no-color >"$tmp_dir/manifest-owner" 2>&1; then
    echo 'hilmake accepted a manifest belonging to another project' >&2
    exit 1
fi
grep -F 'belongs to another project' "$tmp_dir/manifest-owner" >/dev/null
test -x "$manifest_prefix/bin/hilmake-test"
rm -rf "$manifest_prefix"

long_project="$tmp_dir/long-Hilbertfile"
python3 - "$long_project" <<'PYLONG'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text('PROJECT X;\nROOT "' + ('a' * 1100) + '";\nEND X.\n')
PYLONG
if "$HILMAKE" show -f "$long_project" --no-color >"$tmp_dir/long-token" 2>&1; then
    echo 'hilmake accepted a silently truncated Hilbertfile token' >&2
    exit 1
fi
grep -F 'Hilbertfile token exceeds 1023 bytes' "$tmp_dir/long-token" >/dev/null

hash_dir="$tmp_dir/content hash"
mkdir -p "$hash_dir"
cat >"$hash_dir/Main.hil" <<'HIL'
MODULE CacheContent;
CONST Value = 1;
BEGIN
  ASSERT(Value = 1)
END CacheContent.
HIL
cat >"$hash_dir/Hilbertfile" <<HFILE
PROJECT CacheContent;
ROOT "$hash_dir/Main.hil";
OUTPUT "$hash_dir/cache-content";
BUILD_DIR "$hash_dir/cache";
PROFILE RELEASE;
END CacheContent;
HFILE
"$HILMAKE" build -f "$hash_dir/Hilbertfile" --no-color >/dev/null
cp -p "$hash_dir/Main.hil" "$hash_dir/original-time"
sed -i 's/Value = 1/Value = 2/g' "$hash_dir/Main.hil"
touch -r "$hash_dir/original-time" "$hash_dir/Main.hil"
"$HILMAKE" build -f "$hash_dir/Hilbertfile" --no-color >"$tmp_dir/content-rebuild"
grep -F 'compile CacheContent' "$tmp_dir/content-rebuild" >/dev/null

"$HILMAKE" clean -f tests/Hilbertfile.division --no-color >/dev/null
"$HILMAKE" clean -f tests/Hilbertfile.signal --no-color >/dev/null
"$HILMAKE" clean -f tests/Hilbertfile.exit-status --no-color >/dev/null

echo 'hilmake tests ok'
