[zrno](../README.md) / [How zrno works](README.md) / Several CPUs

# Several CPUs

`make run` boots one processor. The kernel starts every processor the firmware lists. User threads of one process can run on several of them at once. Kernel code cannot. One lock, taken on entry and dropped on the way back to user mode, covers every kernel path. [The CPU](cpu.md) defines the lock. This chapter is what the other processors do with it.

`make run-smp` asks QEMU for four processors. `make test-qemu-smp` asks for two and waits until an application processor logs that it is online. Both force the software emulator. The hypervisor accelerator on the development machine does not boot this guest.

## Starting them

`main` takes the kernel lock, calls `smp.start`, spawns `/init`, and then stores `smp.live`. The lock is held across that whole stretch, so a new processor cannot enter the scheduler until `/init` exists.

`kernel/src/sys/smp.zig` reads the MADT. One enabled local APIC is kept per APIC id, and the bootstrap processor is left out. Each remaining id gets a `CPU` from the heap and an idle thread that is not on the ready list. The `CPU` is zeroed and then given a real GDT before the startup message. A zeroed GDT has a null code selector, and the first far return on that processor would fault.

The trampoline is the frame [Memory](memory.md) reserved below 1 MiB. An application processor begins in real mode. Real mode fetches from the first megabyte and loads CR3 with a 32-bit move, so `smp.start` panics if the kernel page-table root does not fit in that width. The page is identity-mapped for the transition, and only in the kernel root. It is not part of the shared higher half, so a cloned address space never contains it. The page is filled with a real-mode stub and targeted with INIT and then SIPI. The SIPI vector is the page frame number.

The stub enables PAE, sets long mode and the NX enable in `EFER`, and only then turns paging on in CR0. The NX bit in a page-table entry is reserved unless that enable is already set, and the kernel stacks are non-executable, so paging first would fault on the way into the kernel. The far jump into long mode uses a small GDT stored in that same page. That table is only for the transition. `apEnter` then loads the `CPU` object's GDT, the one installed before the SIPI.

`apEnter` does not allocate or log. The bootstrap processor still holds the kernel lock, and the lock is what serializes the console. The new processor marks itself online and spins, serving TLB requests, until `smp.live`. The bootstrap processor logs `ap online` once it sees that flag. The new processor then programs its local APIC timer with the count the bootstrap processor measured, takes the kernel lock, and yields onto its idle thread.

The trampoline page is unmapped once every processor has stored online. The frame stays reserved. A processor can still have the translation cached until its next CR3 reload, which is why the page is not reused.

## Who keeps time

Every core's timer fires at 1 kHz and calls the scheduler. Only the bootstrap processor's handler advances the tick, wakes sleepers, and drains the serial port. The others acknowledge the interrupt and reschedule. Two cores do not run the clock at double speed, and a byte arriving on COM1 is delivered once. See [The console](console.md).

A thread marked ready on one core is not pushed at the others. There is no reschedule interrupt. An idle core notices it at the next tick. The ready list is still the single list in [Processes and the scheduler](scheduler.md).

## What overlaps

A syscall holds the lock until it returns, so the bodies of two syscalls never run together. User code holds no lock. Two threads of one process, or of two processes, execute at the same time. They share page tables when they share a process, and the kernel half of those tables is shared with everyone.

The idle halt is the other place a core runs without the lock. It dropped the lock, enabled interrupts, and halted. A timer tick or an inter-processor interrupt wakes it.

## The TLB

Reloading CR3 drops translations on the core that reloaded it. The global bit is clear, so the drop on that core is complete. Other cores keep the translations they already had.

After the kernel clears a page-table entry, it writes one word into the target `CPU.tlb_req` and sends interrupt `0xf0`. Zero means the target is idle. `1` means reload CR3. Any other value is a page-aligned virtual address, and the target executes `invlpg` on it. A page address cannot be `1`, because pages are 4 KiB aligned, so the two requests stay distinct. One word holds one address, so a longer range is a CR3 reload. User ranges are still split into chunks of 64 pages. The physical addresses of that chunk sit on the sender's kernel stack until the target stores zero, and only then are the frames freed. One such chunk covers a 16-page stack.

A core in user mode, or halted, takes the interrupt. The handler flushes, acknowledges, and returns. It does not take the kernel lock. The holder of the lock is often the sender, and taking it here would deadlock. A core spinning for the lock has interrupts off, so the interrupt is not delivered. The spin loop reads the same request word and does the flush itself.

Kernel stacks go through this path, because they are mapped in every address space. User mappings do too. A first mapping of an address that was never present does not send a shootdown. The core that installs the entry still executes `invlpg`, because a not-present translation may be cached. Other cores are told when a present entry is removed.

Clearing an entry stores zero in one write. The address and the flags share the entry. Writing a physical address of zero and leaving the flags would publish a present page at frame 0, for any core walking the table without the lock, until a second store cleared the present bit.

## Leaving an address space

Exiting a process frees its page tables. Another core might be executing in them, including a core that is spinning for the lock and therefore cannot take an interrupt that needs the lock.

`dismantle` sends interrupt `0xf1` first. A target whose current page table is the dying one switches to the kernel root and acknowledges before it tries to take the lock. A spinner does the same switch inside the lock loop. The exiting core then waits until those threads are marked stopped, stops any thread still in the process, and only then frees user pages and the page-table root. The remote core frees its own kernel stack after it has scheduled onto something else.

`dropAddressSpace` repeats the evacuation. Destroying a root pulls every other core off it even when the earlier pass already did.

## Panic

A panic stores a flag and NMIs every other core whose local APIC is up. The NMI handler checks the flag before it considers the lock, and halts. The panicking core may still hold the lock. A second panic on the core that is already printing just halts. An NMI while nobody is panicking prints and then stops the others.

## `cores`

`cores` (`0x52`) writes a header and then one row per started processor, bootstrap first. The header is the vendor string, family, model, the TSC frequency in Hz, and the number of usable 4 KiB pages. A row is the APIC id, whether that local APIC has been initialized, the idle thread's tid, and the tid currently running there. A core that has not scheduled yet reports an absent tid. A halted core's current tid equals its idle tid.

The online column means the local APIC has been programmed. An application processor also sets its own flag when the trampoline finishes, but the bootstrap processor never sets that flag, so the column uses the APIC state.

A ready thread appears in `ps` and in no core's row. Nothing records which core ran a thread last, and nothing accounts ticks to a thread.

## Where to read

- `kernel/src/sys/smp.zig`, `kernel/src/acpi/madt.zig`
- `cpu.shootdown`, `cpu.evacuate`, and `cpu.serviceTlb` in `kernel/src/sys/cpu.zig`
- The `0xf0` and `0xf1` handlers in `kernel/src/sys/ivt.zig`
- `dismantle` and the timer split in `kernel/src/sched/sched.zig` and `kernel/src/sys/ivt.zig`

Previous: [The console](console.md). Next: [Userspace](userspace.md).
