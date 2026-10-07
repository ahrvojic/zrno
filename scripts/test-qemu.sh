#!/bin/sh
# Boot on serial, wait for READY., poweroff, and check that QEMU exits.
# Usage: test-qemu.sh QEMU [QEMUFLAGS...]
# QEMUFLAGS includes firmware and the disk.

set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 QEMU [QEMUFLAGS...]" >&2
    exit 2
fi

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
"$qemu" "$@" -display none -no-reboot \
    < "$fifo" > "$out" 2>&1 &
qpid=$!

n=0
while [ "$n" -lt 90 ]; do
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
[ "$n" -lt 90 ] || fail "timeout waiting for READY."

if ! grep -Fq "virtio-blk " "$out"; then
    fail "virtio-blk did not attach"
fi

printf 'poweroff\n' >&3
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

echo "test-qemu ok"
