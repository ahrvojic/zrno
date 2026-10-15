# Processes and the scheduler

A process owns an address space, a file table, a working directory, and a name. A thread owns a kernel stack, a saved context, and a place on one ready list. `spawn` is how a program starts. The scheduler is round-robin over that list, plus the idle thread on each core.

## The two objects

`Process` and `Thread` live in `kernel/src/sched/proc.zig`.

A process has a pid, a parent pid, and a zombie flag. It has the page tables from [Memory](memory.md), the break and the mmap cursor, a table of 16 file descriptors, a reference to its current directory, and a name. The name is the last component of the path it was spawned from, cut to 24 bytes. Pid 0 is the kernel process, and its name is `idle`.

A thread has a tid, a status (`ready`, `running`, `sleeping`, `waiting`), and a pointer to its process. It also has a saved register frame, an XSAVE image in its own allocation, a kernel stack, a user stack (zero for a kernel thread), and the address it is sleeping on.

Two lists in `kernel/src/sched/state.zig` hold every process, including zombies, and every thread except the idle threads. A process does not keep its own thread list. The threads of one process are the entries in the global list whose parent is that process. The kernel lock from [The CPU](cpu.md) makes those walks safe on more than one core.

Tids and pids are allocated from a counter and are not reused for the life of the boot.

## Spawn

`spawn` (`0x01`) takes a path, an argument vector, and three file descriptors that become the child's stdin, stdout, and stderr. The path and each argument are a pointer and a length. There are at most 32 arguments, and each is at most 512 bytes.

`kernel/src/sched/exec.zig` creates a process, clones the kernel half of the page tables, and loads the ELF. A file whose bytes are the initramfs is loaded straight from that slice. An owned file is read a page at a time into the pages just allocated. There is no intermediate copy of the whole file. Up to eight load segments are allowed, they must sit below the mmap region, and a writable segment cannot also be executable. The break is set to the end of the image.

The first thread gets a 16-page user stack, mapped immediately, with the argument vector on it. The child inherits the parent's working directory (a new reference, not a copy of the path). The three descriptors are looked up in the parent and installed in the child. `/init` is spawned by the kernel rather than by a process, and it gets the console on 0, 1, and 2.

The child is marked ready and the call returns. The parent keeps running. Another core notices the new thread the next time it looks at the ready list, which is its next timer tick. Nothing sends a reschedule interrupt.

`thread` (`0x10`) starts another thread in the same process. It shares the page tables and the file table, gets its own user stack and its own kernel stack, and takes one argument in `rdi`. `thread_exit` (`0x11`) unmaps that user stack. When the last thread of a process exits, the process becomes a zombie. `gettid` (`0x12`) and `yield` (`0x13`) are the rest of that block.

There is no `fork` and no `exec`. A new program is a new process, with exactly the three descriptors the caller passed.

## Wait, zombies, and Ctrl-C

`wait` (`0x02`) sleeps until a child is a zombie. Passing a pid waits for that child. Passing zero waits for any. The zombie stays in the process list until the parent collects it, and then its object is freed. A child whose parent is already gone is reparented to pid 1, and `/init` collects it.

A `wait` for a specific pid also marks that process as the foreground. Ctrl-C on the console asks the scheduler to stop the foreground process. It exits with status 130, and the foreground mark is cleared. A process that dies from a fault exits with 128 plus the vector, so a page fault is 142. The shell prints that status as a number.

If pid 1 exits, the kernel panics. The boot path has nothing else to run.

## One trip through the scheduler

`schedule` in `kernel/src/sched/sched.zig` runs from the timer and from any call that blocks. Blocking code marks the thread and raises interrupt `0x90`, so the switch happens inside the call.

The current thread, if it was running, is marked ready first, so the search can choose it again. The search starts at the next thread in the list and takes the first one whose status is ready. If nobody is ready, the core runs its idle thread.

When the chosen thread is the one already running, `schedule` marks it running and returns. The interrupt frame, the FPU registers, and CR3 are already right. A `yield` takes this path when the caller is the only ready thread. A short syscall never reaches `schedule`.

A real switch saves the register frame and the XSAVE image, switches to the next process's page tables, points the syscall and interrupt stack at the top of the next thread's kernel stack, and restores the frame and the FPU. The FPU is saved on every real switch. Userspace is built with AVX, so the saved image includes that state.

## Idle

Each core has an idle thread, created off the ready list. It runs only when nobody else is ready. Its initial flags have interrupts off. The idle loop drops the kernel lock, enables interrupts, and halts. Those two instructions are adjacent, so the interrupt arrives after the halt has started. On the way back it disables interrupts, takes the lock, and raises `0x90` to look for work.

The idle thread is the only kernel context that runs with interrupts on. Every other kernel path holds the lock and keeps interrupts off.

## Sleep and wake

`sched.wait` records an address on the thread, marks it waiting, and schedules. The kernel lock is held across the caller's condition check and that status store, and it stays held, so a wake on another core cannot land in between and get lost. `sched.wakeup` walks the thread list and marks every waiting thread on that address ready. It is a broadcast. The sleeper checks its condition again after it runs.

The address is a kernel pointer. Pipe reads sleep on the ring's buffer and pipe writes sleep on the ring's head. A terminal read sleeps on the input ring. `sleep` stores a tick instead, and the bootstrap processor's timer walks the list once per tick.

`wait_word` (`0x14`) and `wake_word` (`0x15`) are the same pair for a user address. The address is an aligned `u64` in the calling process, and it is the channel. The wait sleeps only while the word still holds the expected value. The wake wakes waiters of this process only, and returns how many. The waker stores the new value, then wakes. A wake can arrive with the word already changed, so the caller checks it again. Two processes can use the same numeric address. The match is limited to the calling process, so they do not wake each other.

`poll` sleeps this way too, on the file table, but the conditions it checks are a file concern. See [Files](files.md).

## Kernel stacks

`kernel/src/sched/kstack.zig` hands out stacks from a 1 GiB window in the shared high half, starting at `0xffffff0000000000`. Each stack is 16 pages with a guard page below it. A bitmap remembers holes under the high-water mark, so freeing a stack in the middle does not lose the address. The window is mapped into every process by the shared kernel half.

Because the mapping is shared, unmapping a stack on this core does not remove it from another core's TLB. `free` shoots the range down before it returns the frames. A fault on the guard page is a fatal kernel overflow.

The boot stack from the loader is not in this window. The first schedule that has a current thread drops it and returns those frames to the physical allocator.

## `ps`

`ps` (`0x05`) fills the caller's buffer with one fixed-size row per thread, and one row for a zombie process that no longer has threads. The row is the tid, pid, parent pid, state, and the process name. Threads of one process share the name. A zombie has no thread left, so its tid is empty. The caller's buffer is capped at a page.

A row does not name the core the thread is on. A ready thread has no core. The core list is a different call, described in [Several CPUs](smp.md).

## Where to read

- `kernel/src/sched/proc.zig`, `kernel/src/sched/thread.zig`, `kernel/src/sched/state.zig`
- `kernel/src/sched/sched.zig`, `kernel/src/sched/exec.zig`, `kernel/src/sched/kstack.zig`
- `kernel/src/sys/elf.zig` for the loader
- The yield stub and the timer call into `schedule` are in `kernel/src/sys/ivt.zig`
