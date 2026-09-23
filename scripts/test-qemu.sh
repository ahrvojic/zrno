#!/bin/sh
# Boot the ISO on serial, wait for READY., run a couple of shell commands,
# poweroff, and check the output. Usage: test-qemu.sh ISO QEMU [QEMUFLAGS...]

set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: $0 ISO QEMU [QEMUFLAGS...]" >&2
    exit 2
fi

iso=$1
shift
qemu=$1
shift

workdir=${TMPDIR:-/tmp}/zrno-qemu.$$
mkdir "$workdir"
fifo=$workdir/in
out=$workdir/out
mkfifo "$fifo"
touch "$out"

qpid=
cleanup() {
    if [ -n "$qpid" ]; then
        kill "$qpid" 2>/dev/null || :
        wait "$qpid" 2>/dev/null || :
    fi
    rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

fail() {
    echo "$1" >&2
    cat "$out" >&2
    exit 1
}

# RDWR so open does not block waiting for the other end.
exec 3<>"$fifo"
"$qemu" "$@" -display none -no-reboot -cdrom "$iso" -boot d \
    < "$fifo" > "$out" 2>&1 &
qpid=$!

n=0
while [ "$n" -lt 30 ]; do
    if grep -Fq "READY." "$out"; then
        break
    fi
    if ! kill -0 "$qpid" 2>/dev/null; then
        wait "$qpid" || :
        qpid=
        fail "qemu exited before READY."
    fi
    n=$((n + 1))
    sleep 1
done
[ "$n" -lt 30 ] || fail "timeout waiting for READY."

printf 'echo hi | cat\nls\nthread\npoweroff\n' >&3
exec 3>&-

n=0
while [ "$n" -lt 30 ]; do
    if ! kill -0 "$qpid" 2>/dev/null; then
        wait "$qpid" || :
        qpid=
        break
    fi
    n=$((n + 1))
    sleep 1
done
[ -z "$qpid" ] || fail "qemu did not exit after poweroff"

# Serial is CRLF; strip CR so whole-line matches work.
# Skip `cat` (glued to the prompt under type-ahead) and `ls` (echoed command).
tr -d '\r' < "$out" > "$out.plain"
missing=
for line in hi init ps shell; do
    if ! grep -Fxq "$line" "$out.plain"; then
        echo "missing line: $line" >&2
        missing=1
    fi
done
# Prompt and program output share a line under type-ahead (`> thread ok`).
if ! grep -Fq "thread ok" "$out.plain"; then
    echo "missing line: thread ok" >&2
    missing=1
fi
[ -z "$missing" ] || fail "qemu serial output:"

echo "test-qemu ok"
