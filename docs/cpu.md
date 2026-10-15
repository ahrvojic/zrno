# The CPU

Every core has a `CPU` object. The kernel enters through a syscall or an interrupt, takes one lock, and runs to completion with interrupts off. Time comes from the local APIC timer, calibrated from whatever firmware timer is actually there.

## The processor record

`IA32_GS_BASE` holds the address of the running `CPU`. `current()` is a load from `%gs`. The bootstrap processor's object is static. Each application processor gets one from the heap, interrupt stacks included. See [Several CPUs](smp.md).

`cpu.init` loads the GDT, clears the GS selector, and then writes the MSR. A selector left behind by the firmware would take the GS base from the GDT instead of from this object. The entry path does not use `swapgs`. On a syscall, an interrupt, or a fault, GS already addresses the kernel record. User code does not load GS, and `CR4.FSGSBASE` is clear, so `wrgsbase` from user mode is an illegal instruction.

The object holds the GDT, the TSS, the interrupt stacks, the syscall stack pointer, the thread currently running, and the words the other cores use to request a TLB flush or a change of address space.

## Segments and the IDT

The GDT is five selectors, in an order `SYSRET` requires. Kernel code, kernel data, user data, user code, then a TSS descriptor. `SYSRET` derives the user selectors from one base value, so user data has to sit immediately after kernel data and user code immediately after that. `IRET` takes its selectors from the interrupt frame and does not care about the order. Reloading the GDT reloads CS, DS, ES, and SS. It leaves FS and GS alone, because loading a data selector into GS would zero the hidden base.

The IDT is all interrupt gates, so the hardware clears the interrupt flag on entry. The local APIC timer is vector 32 and the keyboard is vector 33. Yield is a software interrupt, `0x90`. Two more vectors, `0xf0` and `0xf1`, are inter-processor interrupts and are described in [Several CPUs](smp.md).

NMI, double fault, and page fault use dedicated stacks in the TSS (the IST). A page fault in particular can happen while the syscall entry has not switched stacks yet, or while the kernel stack itself is the thing that faulted. Those paths assume GS already points at this `CPU`.

`cpu.init` also sets write protect, SMEP, and SMAP, and enables XSAVE for the state userspace actually uses. Userspace is built with AVX and AVX2, so the saved image is the x87, SSE, and AVX state.

## Entering on a syscall

`SYSCALL` is the only way in from a program. The entry point is `syscallEntry` in `kernel/src/sys/ivt.zig`. The CPU saves the return address in `rcx` and the flags in `r11`, and loads the kernel CS. The flag mask programmed at init clears the interrupt flag, the direction flag, and the trap and alignment flags, so the body of every syscall runs with interrupts off.

Arguments are `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`. `rcx` is not an argument, because the instruction overwrote it. `rax` is the call number on the way in and the result on the way out. A negative result is the negated errno.

The entry stub saves the user stack pointer and loads the kernel one through two offsets from GS. Those offsets are computed from the `CPU` layout. They are not constants in the assembly, because the compiler is free to reorder the struct. The kernel stack pointer matches `TSS.rsp0`, which is also what an interrupt from user mode will load.

The kernel lives in the upper half of the calling process's page tables, so a syscall does not reload CR3. SMAP is on, and copies to and from user memory are explicit.

The return is `SYSRET` when `rcx` and `r11` are still the values this entry saved. That is the normal case. If the scheduler resumed some other thread onto this frame, those registers belong to that thread and `SYSRET` would clobber them with the frame's instruction pointer and flags. The epilogue compares and falls into `iret` on a mismatch, which restores `rcx` and `r11` from the frame. A call that blocked never reaches this epilogue. It comes back through the yield interrupt, whose stub always returns with `iret`.

## The lock

`kernel/src/sys/lock.zig` is one word, taken with `xchg`. Zero is free. The owner is recorded so a core that takes it twice panics instead of deadlocking on itself.

The rule is the interrupt flag. Entry takes the lock when the interrupted frame had interrupts on: user code, or the idle halt. The yield interrupt and a fault that happened inside the kernel already hold it, and must not take it again. The lock is released only when the frame about to run has interrupts on. `sched.wait` does not drop it. The thread that parked holds nothing. The core that stays in the kernel keeps the lock and runs someone else.

A core in the kernel is therefore not preempted, and two cores do not run kernel code at once. User code on two cores does overlap, because the lock was dropped on the way out. The spin loop also services this core's TLB request and steps off a dying address space. Interrupts are off while it spins, so those requests would otherwise sit unanswered. See [Several CPUs](smp.md).

`main` takes the lock before it starts the other processors, and the boot path's final yield drops it when the first user thread runs.

## The clock

The timer interrupt is 1 kHz on the local APIC. `kernel/src/dev/timer.zig` calibrates the APIC count against a reference for about 10 ms, trying the HPET, then the ACPI PM timer, then PIT channel 2. The first one that answers programs the APIC and returns. If none of them answers, the kernel panics. All three stay, because a machine may have any one of them.

The TSC frequency prefers CPUID leaf `0x15`, read during early identify. When that leaf is missing or returns zero, the same calibration window counts `rdtsc` against the reference that just worked. `uptime` (`0x41`) returns nanoseconds since boot once a frequency is known. Before that it returns the tick count in milliseconds. Log lines gain a timestamp only after the frequency exists. `sleep` (`0x40`) records a wake tick and parks. The scheduler chapter describes who walks the sleepers.

Only the bootstrap processor's timer advances the tick count and drains the serial port. Every other core's timer interrupt only reschedules. See [Several CPUs](smp.md).

## ACPI

The loader passed a physical RSDP. `kernel/src/acpi/acpi.zig` maps it through the direct map. Revision 2 and later use the XSDT. An older revision, or a bad XSDT, uses the RSDT.

Four tables matter:

- The MADT lists local APICs, the I/O APIC, and IRQ overrides. It is how the other processors are found, and how the keyboard is routed.
- The FADT provides the reset register, the PM timer, and whether an 8042 is present. A hardware-reduced FADT means the legacy blocks are absent, and boot panics. The kernel does not run on that kind of machine.
- The HPET table, when present, locates the HPET.
- The DSDT is parsed far enough to find `_S5_`, the power-off values.

`reboot` (`0x50`) writes the FADT reset register, and falls back to the 8042 pulse `0xFE`. `poweroff` (`0x51`) writes the `_S5_` values. Both close live files and sync `/tmp` first. [Files](files.md) describes that sync. The `cores` syscall (`0x52`) is a snapshot of the processor list, described in [Several CPUs](smp.md).

## Where to read

- `kernel/src/sys/cpu.zig`, `kernel/src/sys/gdt.zig`, `kernel/src/sys/idt.zig`, `kernel/src/sys/ivt.zig`
- `kernel/src/sys/lock.zig`, `kernel/src/sys/fpu.zig`
- `kernel/src/dev/timer.zig`, `kernel/src/dev/hpet.zig`, `kernel/src/dev/pmtimer.zig`, `kernel/src/dev/pit.zig`
- `kernel/src/acpi/acpi.zig`, `kernel/src/acpi/madt.zig`, `kernel/src/acpi/fadt.zig`, `kernel/src/acpi/dsdt.zig`
