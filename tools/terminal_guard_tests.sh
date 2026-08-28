#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$tmp/bin" "$tmp/libexec/hilbert"
cp "$root/tools/hilbert-launcher.sh" "$tmp/bin/hilbert"
cat >"$tmp/libexec/hilbert/hilbert" <<'CHILD'
#!/bin/sh
stty -echo -onlcr </dev/tty
exit 7
CHILD
chmod +x "$tmp/bin/hilbert" "$tmp/libexec/hilbert/hilbert"

python3 - "$tmp/bin/hilbert" <<'PY'
import os
import pty
import sys

launcher = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    command = (
        'before=$(stty -g </dev/tty); '
        + repr(launcher)
        + '; rc=$?; after=$(stty -g </dev/tty); '
        + 'printf "RC=%s\\nBEFORE=%s\\nAFTER=%s\\n" "$rc" "$before" "$after"'
    )
    os.execl('/bin/sh', 'sh', '-c', command)

output = bytearray()
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    output.extend(chunk)
_, status = os.waitpid(pid, 0)
os.close(fd)
text = output.decode(errors='replace').replace('\r', '')
values = {}
for line in text.splitlines():
    if '=' in line:
        key, value = line.split('=', 1)
        values[key] = value
if values.get('RC') != '7':
    raise SystemExit('launcher did not preserve the child exit status')
if not values.get('BEFORE') or values.get('BEFORE') != values.get('AFTER'):
    raise SystemExit('launcher did not restore the controlling terminal state')
if os.waitstatus_to_exitcode(status) != 0:
    raise SystemExit('terminal guard harness failed')
PY

echo 'terminal guard tests ok'
