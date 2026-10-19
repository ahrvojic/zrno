[zrno](../README.md) / [How zrno works](README.md) / Userspace

# Userspace

Userspace is a handful of freestanding programs packed into the initramfs. `/init` is pid 1. It spawns a shell, and the shell spawns everything else. The library they share is a thin wrapper over the syscalls the earlier chapters defined.

## How a program is built

`user/build.zig` compiles every `user/src/cmd/*.zig` into its own static binary. The Makefile packs those binaries into a ustar archive, and the loader hands that archive to the kernel. A program is a name at the root: `/ls`, `/shell`, `/init`.

Each binary is linked with `user/user.ld`. The entry is `_start` in `user/src/lib/start.zig`. It receives the argument vector the kernel placed on the stack and calls `main`. `main` is either `fn () u64` or `fn ([]const []const u8) u64`. The return value is the process exit status. The programs are built small, without compiler-rt, so they do not use 128-bit division or the usual runtime helpers.

`user/src/lib/sys.zig` is the other half of `kernel/src/sys/syscall.zig`. The numbers, the flag bits, and the struct layouts are duplicated by hand and have to stay identical. A wrapper puts the number in `rax`, the arguments in `rdi`, `rsi`, `rdx`, `r10`, `r8`, and `r9`, and executes `syscall`. The fourth argument is `r10` because the instruction overwrites `rcx` with the return address. A negative return is a negated errno. `rcx` and `r11` are clobbered by the instruction, as [The CPU](cpu.md) describes.

`malloc` is a free list. When the list cannot satisfy a request, it asks `mmap` for a new range of whole pages and inserts that range. `free` returns the block to the list and does not unmap the range. The kernel calls are in [Memory](memory.md).

## `/init`

`user/src/cmd/init.zig` checks that floating point and a vector add produce the right answer. A broken XSAVE path fails here, before any prompt, and the kernel panics because pid 1 exited.

It prints `READY.` and spawns `/shell` with the console on stdin, stdout, and stderr. Then it waits for any child. The shell's exit starts another shell. Any other pid is an orphan the kernel reparented, and the wait collects it. The boot test waits for `READY.` and then powers the machine off.

## The shell

`user/src/cmd/shell.zig` reads stdin one byte at a time. The kernel has already cooked the input, so each `read` returns the next byte of a finished line, and the shell assembles the line itself. A line that does not fit its buffer is discarded, and the shell prints an error.

A token with no `/` in it is a program at the root. `ls` runs `/ls` even after `cd /tmp`. `cd` has to be a builtin, because a child cannot change its parent's directory. `cd` with no argument returns to `/`. The other builtins are `help`, `yield`, `sleep`, `uptime`, `exit`, `reboot`, and `poweroff`. `uptime` prints the `uptime` syscall in milliseconds. `reboot` and `poweroff` do not return. `pwd` is a program, not a builtin. It asks the kernel for the path and writes it out.

Redirection and pipes are arranged before `spawn`, with the three descriptors that call accepts:

- `cmd < file` opens the file and passes it as stdin.
- `cmd > file` opens with write and create, which truncates, and passes it as stdout.
- `cmd >> file` opens with write, create, and keep, seeks to the end, and passes that descriptor.
- `a | b` creates a pipe, passes the write end as `a`'s stdout and the read end as `b`'s stdin, and spawns both.

The shell waits for the specific child it just spawned. That wait is what arms Ctrl-C, so the child exits with status 130. The shell prints a non-zero status as a number.

## The other programs

The commands are small wrappers around one or two syscalls.

- `cat` copies a file, or stdin, to stdout. A broken pipe makes it exit with an error.
- `echo` writes its arguments.
- `ls` reads a directory. `mkdir`, `rmdir`, `rm`, and `mv` create, remove, and rename names. They only succeed under `/tmp`.
- `ps` prints one row per thread: tid, pid, parent, state, and the process name. A zombie tid is a dash. The formatting lives in the program. The kernel returns plain rows.
- `cores` prints the vendor, family, model, TSC frequency, and usable memory, then one row per started processor. A ready thread has no row here. It has a row in `ps`.
- `bench` times an empty loop, `getpid`, `yield`, a one-byte pipe round trip, a full pipe, `spawn` from the initramfs and from `/tmp`, a file read, `map_file`, and anonymous `mmap`. When `cores` reports two or more processors it adds pairs of processes that burn cycles, do arithmetic, or walk memory, to show the second core overlapping the first. No other program starts a thread.

`thread`, `wait_word`, and `poll` have wrappers in `sys.zig` and no caller under `user/src/cmd`. Programs that run at the same time are separate processes. The shell's pipeline is the usual case.

## Where to read

- `user/src/lib/start.zig`, `user/src/lib/sys.zig`, `user/src/lib/lib.zig`, `user/src/lib/malloc.zig`
- `user/src/cmd/init.zig`, `user/src/cmd/shell.zig`
- `user/build.zig`, `user/user.ld`

Previous: [Several CPUs](smp.md).
