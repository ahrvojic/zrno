# How zrno works

These chapters follow the kernel as it comes up. Each one describes how that part works: the structures that matter, and one path through them. Syscall numbers are given in the chapter that implements them. `kernel/src/sys/syscall.zig` and `user/src/lib/sys.zig` are the two copies of that list, and they have to match.

The [root README](../README.md) is how to build and run.

1. [Boot](boot.md). The UEFI loader, the handoff, and `main` through `/init`.
2. [Memory](memory.md). Physical frames, page tables, the heap, and the user address space.
3. [The CPU](cpu.md). How execution enters the kernel, the lock, and the clock.
4. [Processes and the scheduler](scheduler.md). Spawn, threads, the run queue, and sleep.
5. [Files](files.md). The name tree, `/`, `/tmp`, the block cache, and pipes.
6. [The console](console.md). Serial, the framebuffer, and the cooked terminal.
7. [Several CPUs](smp.md). Starting the other processors, the TLB, and a dying address space.
8. [Userspace](userspace.md). `/init`, the shell, and the library the programs share.
