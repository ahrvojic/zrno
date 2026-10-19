[zrno](../README.md) / [How zrno works](README.md) / The CPU

# The CPU

Every core has a `CPU` object. The kernel enters through a syscall or an interrupt, takes one lock, and runs to completion with interrupts off. Time comes from the local APIC timer, calibrated from whatever firmware timer is actually there.

## The processor record

`IA32_GS_BASE` holds the address of the running `CPU`. `current()` is a load from `%gs`. The bootstrap processor's object is static. Each application processor gets one from the heap, interrupt stacks included. See [Several CPUs](smp.md).

`cpu.init` loads the GDT, clears the GS selector, and then writes `IA32_GS_BASE`. A non-null GS selector makes the CPU take the base from the GDT and ignore that MSR. Loading a null selector does not itself change the hidden base, so the `WRMSR` that follows is what publishes this `CPU`. The entry path does not use `swapgs`. `SYSCALL` does not change GS, and nothing ever writes a user base into `IA32_KERNEL_GS_BASE`, so there is no second base to exchange. On a syscall, an interrupt, or a fault, GS already addresses the kernel record. User code does not load GS, and `CR4.FSGSBASE` is clear, so `wrgsbase` from user mode is an illegal instruction.

The object holds the GDT, the TSS, the interrupt stacks, the syscall stack pointer, the thread currently running, and the words the other cores use to request a TLB flush or a change of address space.

## Segments and the IDT

The GDT is five selectors. Kernel code, kernel data, user data, user code, then a TSS descriptor. `SYSCALL` loads CS from `STAR[47:32]` and SS from that value plus 8, so kernel data has to sit immediately after kernel code. `SYSRET` loads SS from `STAR[63:48]+8` and CS from `STAR[63:48]+16`. That base is kernel data with RPL 3 (`0x13`), so the additions land on user data and user code and stay at RPL 3. `iretq` takes CS and SS from the interrupt frame and would accept any order. Reloading the GDT reloads CS, DS, ES, and SS. It leaves FS and GS alone, because loading a data selector into GS would zero the hidden base.

The IDT is all interrupt gates, so the hardware clears the interrupt flag on entry. It does not clear the direction flag or the alignment flag. Both entry stubs execute `cld` and `clac`, so a user `std` cannot reverse a kernel copy and a user who set AC cannot turn SMAP off for the handler. The local APIC timer is vector 32 and the keyboard is vector 33. Yield is a software interrupt, `0x90`. Two more vectors, `0xf0` and `0xf1`, are inter-processor interrupts and are described in [Several CPUs](smp.md).

NMI, double fault, and page fault name an IST index in their gates. The CPU loads the stack from `TSS.ist[index - 1]` instead of from the stack that was current, and instead of from `TSS.rsp0`. That is a known-good stack when the current one is the thing that faulted, or when RSP still points at user memory. `SYSCALL` does not switch stacks in hardware. The entry stub does it with the next instructions, and `FMASK` does not mask NMI, so an NMI in that window would push its frame on the user stack if the NMI gate used IST 0. The window is the instruction that stores the user RSP, before the next instruction loads the kernel RSP. NMI, double fault, and page fault each have their own slot. A fault during NMI reloads that same IST, so sharing the page-fault stack would recurse. A page fault can also happen while the syscall entry has not switched stacks yet, or while the kernel stack itself is the thing that faulted. Those paths assume GS already points at this `CPU`.

`cpu.init` sets CR0.WP, SMEP, and SMAP, and enables XSAVE for the state userspace actually uses. WP makes ring 0 honor the read-only bit, so a stray store through the kernel text mapping faults. SMEP makes an instruction fetch from a user page fault. SMAP makes a kernel data access through a user address fault unless AC is set. The copy path does not toggle AC and does not touch the user virtual address. It walks the page tables and copies through the direct map, which SMAP allows. Userspace is built with AVX and AVX2, so the saved image is the x87, SSE, and AVX state. `CR4.OSXSAVE` is set and `XCR0` selects that state. `XSAVE` and `XRSTOR` run on a real context switch.

## Entering on a syscall

`SYSCALL` is the only way in from a program. The entry point is `syscallEntry` in `kernel/src/sys/ivt.zig`, and `LSTAR` holds that address. The CPU saves the return address in `rcx` and the flags in `r11`, loads CS and SS from `STAR`, and applies `FMASK` to the flags. `FMASK` clears IF, DF, TF, AC, NT, and IOPL, so the body of every syscall runs with interrupts off and with the direction and alignment flags clear. An interrupt gate clears IF only. The stubs clear DF and AC again because a timer or a fault is not a `SYSCALL`.

Arguments are `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`. `rcx` is not an argument, because the instruction overwrote it with the return address. The library passes the fourth argument in `r10` for that reason. `rax` is the call number on the way in and the result on the way out. A negative result is the negated errno.

`SYSCALL` does not switch stacks and does not read `TSS.rsp0`. The entry stub saves the user stack pointer and loads the kernel one through two offsets from GS. Those offsets are computed from the `CPU` layout. They are not constants in the assembly, because the compiler is free to reorder the struct. The stored kernel pointer matches `TSS.rsp0`, which is what an interrupt from user mode loads on its own.

The kernel lives in the upper half of the calling process's page tables, so a syscall does not reload CR3. SMAP is on. Copies go through the direct map, as the previous section describes.

The return is `sysretq` only when this entry's registers are still the ones it saved and the frame is an ordinary user return. The stub compares `rcx` with the saved RIP and `r11` with the saved flags. It also requires user CS and user SS, a clear trap flag and resume flag, and a canonical RIP and RSP, meaning bits 63:47 clear. `SYSRET` loads RIP from `rcx` and the flags from `r11`, and it builds CS and SS from `STAR`. It cannot put a thread's real `rcx` and `r11` back, and it cannot restore TF or RF. If the scheduler resumed some other thread onto this frame, those registers belong to that thread. The epilogue falls into `iretq`, which restores them from the frame. A non-canonical RIP or RSP does not take that `iretq` either. `syscallDispatch` kills the process first. An `iretq` that faults on a bad stack in this stub has nowhere to land. `SYSCALL` is two bytes, so an instruction in the last two bytes of the user range would leave the next address in `rcx`. That address has bit 47 set and bits 63:48 clear, which is not the user form above, so it is non-canonical and `SYSRET` faults on it. [Memory](memory.md) leaves that page unmapped, which keeps the instruction from running there. A call that blocked never reaches this epilogue. It comes back through the yield interrupt, whose stub always returns with `iretq`.

## The lock

`kernel/src/sys/lock.zig` is one word, taken with `xchg`. Zero is free. The owner is recorded so a core that takes it twice panics instead of deadlocking on itself.

The rule is the interrupt flag. Entry takes the lock when the interrupted frame had interrupts on: user code, or the idle halt. The yield interrupt and a fault that happened inside the kernel already hold it, and must not take it again. The lock is released only when the frame about to run has interrupts on. `sched.wait` does not drop it. The thread that parked holds nothing. The core that stays in the kernel keeps the lock and runs someone else.

A core in the kernel is therefore not preempted, and two cores do not run kernel code at once. User code on two cores does overlap, because the lock was dropped on the way out. The spin loop also services this core's TLB request and steps off a dying address space. Interrupts are off while it spins, so those requests would otherwise sit unanswered. See [Several CPUs](smp.md).

`main` takes the lock before it starts the other processors, and the boot path's final yield drops it when the first user thread runs.

## The clock

The timer interrupt is 1 kHz on the local APIC. The APIC timer counts down in bus cycles and has no frequency of its own, so the initial count that produces a 1 ms period has to be measured. `kernel/src/dev/timer.zig` runs the counter against a reference for about 10 ms, trying the HPET, then the ACPI PM timer, then PIT channel 2. The HPET and the PM timer are free-running counters with a published frequency. PIT channel 2 is the legacy speaker timer. It can be programmed to a known period and polled on its output pin without enabling its interrupt. The first one that answers programs the APIC and returns. If none of them answers, the kernel panics. All three stay, because a machine may have any one of them.

The TSC frequency prefers CPUID leaf `0x15`, read during early identify. The leaf is often present and zero. When it is missing or returns zero, the same calibration window counts `rdtsc` against the reference that just worked. `uptime` (`0x41`) returns nanoseconds since boot once a frequency is known. Before that it returns the tick count in milliseconds. Log lines gain a timestamp only after the frequency exists. `sleep` (`0x40`) records a wake tick and parks. The scheduler chapter describes who walks the sleepers.

Only the bootstrap processor's timer advances the tick count and drains the serial port. Every other core's timer interrupt only reschedules. See [Several CPUs](smp.md).

## ACPI

The loader passed a physical RSDP. `kernel/src/acpi/acpi.zig` maps it through the direct map. Revision 2 and later use the XSDT. An older revision, or a bad XSDT, uses the RSDT.

Four tables matter:

- The MADT lists local APICs and I/O APICs. One enabled local APIC is one processor. An IRQ source override sends an ISA IRQ to a different I/O APIC input. ISA IRQ 1 is the keyboard, and it is not necessarily pin 1, so the route to vector 33 follows the override when the table has one.
- The FADT provides the reset register, the PM timer, the PM1 control blocks, and whether an 8042 is present. A hardware-reduced FADT means those legacy blocks are defined to be absent, and boot panics. The kernel does not run on that kind of machine.
- The HPET table, when present, locates the HPET registers and their frequency.
- The DSDT is parsed far enough to find `_S5_`. That name holds the sleep-type values `poweroff` writes into the PM1 control registers, with the sleep-enable bit set.

`reboot` (`0x50`) writes the FADT reset register, and falls back to the 8042 command `0xFE`, which pulses the processor reset line. The keyboard driver does not have to be running for that command. `poweroff` (`0x51`) writes the `_S5_` values. Both close live files and sync `/tmp` first. [Files](files.md) describes that sync. The `cores` syscall (`0x52`) is a snapshot of the processor list, described in [Several CPUs](smp.md).

## Where to read

- `kernel/src/sys/cpu.zig`, `kernel/src/sys/gdt.zig`, `kernel/src/sys/idt.zig`, `kernel/src/sys/ivt.zig`
- `kernel/src/sys/lock.zig`, `kernel/src/sys/fpu.zig`
- `kernel/src/dev/timer.zig`, `kernel/src/dev/hpet.zig`, `kernel/src/dev/pmtimer.zig`, `kernel/src/dev/pit.zig`
- `kernel/src/acpi/acpi.zig`, `kernel/src/acpi/madt.zig`, `kernel/src/acpi/fadt.zig`, `kernel/src/acpi/dsdt.zig`

Previous: [Memory](memory.md). Next: [Processes and the scheduler](scheduler.md).
