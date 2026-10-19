[zrno](../README.md) / [How zrno works](README.md) / Memory

# Memory

Memory is three layers. A bitmap hands out physical frames. Page tables map those frames into the higher half for the kernel and into the lower half for a process. A process then obtains anonymous memory by mapping downward, and a stack per thread at the top of the user range. The loaded image stays where `spawn` put it.

## Physical frames

A physical frame is one 4 KiB page from the bitmap in `kernel/src/mm/pmm.zig`. Every later mention of a frame in this chapter means one of those pages. `Frame` in `kernel/src/mm/frame.zig` is a kernel-heap object that remembers the address of one of them. The block cache is its only user, and that object is described with the heap below.

The bitmap covers every usable page in the memory map from [Boot](boot.md). Bits start set, meaning taken. Usable pages are cleared. The bitmap itself sits in one of those usable ranges and is marked taken, so it cannot hand itself out.

`alloc` returns a physical address and zeros the frame. Callers turn that into a pointer by adding the higher-half offset. `free` panics on a double free or an address outside the bitmap.

One usable frame in the first 256 pages, never page 0, is taken during init and never returned. The real-mode trampoline that starts another processor has to live below 1 MiB. See [Several CPUs](smp.md).

The loader's own pages are tagged reclaimable. They stay reserved until the first schedule that is running a real thread, which is the point where nothing still uses the boot stack. `reclaimBootloader` clears those bits.

## The kernel map

`kernel/src/mm/vmm.zig` builds a 4-level page table and loads it. The direct map covers every range the boot info said to map: usable RAM, reclaimable loader memory, ACPI, the framebuffer, and the modules. Ordinary RAM entries are 4 KiB, writable, and not executable. The framebuffer is write-combining. That is a PAT entry the kernel programs, not an attribute left by the firmware. `cpu.init` writes `IA32_PAT` so index 5 is write-combining, and the framebuffer entries select that index by setting PWT and PAT and leaving PCD clear. Ordinary RAM stays write-back. Text and read-only data are read-only in this map, and the same pages are mapped again at the link address with the permissions from the linker script: executable, read-only, or read-write.

The upper half of every PML4 is the kernel. PML4 index 256 is the direct map. The top of the higher half holds the kernel image and, later, kernel stacks. A new process gets an empty lower half and a copy of those upper PML4 entries (`cloneKernel`). When the kernel later allocates a page-table page in its own half, that entry is written into every process as well. User mappings stay private.

The global bit is clear on every entry. Set, it would keep a translation across a CR3 reload, which is the usual way to avoid flushing the kernel half on every process switch. This kernel never sets it, so reloading CR3 drops every translation on this core, kernel pages included. Another core can still hold them. Unmapping a page that some other core might have used tells those cores before the frame is freed. The mechanism is in [Several CPUs](smp.md). A first mapping of an address that was never present does not send that shootdown. The mapping core still executes `invlpg`. A not-present translation may be cached, which is why the local flush is there. Other cores are told only when a present entry is cleared.

`switchTo` reloads CR3 only when the root actually changes. A syscall does not switch page tables: the kernel is already mapped in the upper half of the process that called.

## The heap

`kernel/src/mm/heap_core.zig` is a power-of-two allocator. Sizes from 16 bytes up to a page come out of page-sized slabs. Anything larger is a contiguous run of frames, up to 1 GiB. The kernel heap's page source is the physical allocator, and the memory it returns is already mapped through the direct map. Kernel objects come from here: processes, file nodes, and the `Frame` headers.

A `Frame` holds the physical address of one frame and points at that page through the direct map. The block cache creates one `Frame` per slot when the disk comes up, and the slot keeps that same page for every block it caches. `map_file` and anonymous `mmap` take pages from `pmm.alloc` and never allocate a `Frame`.

## A user address space

User addresses run from the first page to `(1 << 47) - 4096`. A user pointer is canonical only when bits 63:47 are clear, so the hardware user range ends at `1 << 47`. `SYSCALL` is two bytes and leaves the address of the next instruction in `rcx`, which is the address `SYSRET` jumps to. Placed in the last two bytes of that range, the instruction would hand `SYSRET` a return address with bit 47 set. The last page is left unmapped so the instruction cannot sit there. [The CPU](cpu.md) describes the second check, which refuses the return if `rcx` or the user stack is non-canonical anyway. The null page is never mapped. What remains is the image, then mappings, then stacks. A cursor moves backward only when the range being freed is the one at its tip. A hole in the middle stays a hole.

| Region | Where it sits | When pages appear |
|---|---|---|
| Program image | Where the ELF asked, below `user_mmap_top` | During `spawn` |
| `mmap` and `map_file` | Down from `user_mmap_top` | `mmap` on the first access; `map_file` during the call |
| Stacks | Down from the top of user space | During the call that creates the thread |

`user_mmap_top` sits 256 MiB below the top. That gap is the stack region. ELF load segments have to land below it. `spawn` records the page-aligned end of the image, and nothing moves that address. A mapping that would cross it is rejected. Stacks stop at `user_mmap_top`, which is always at or above that end. There is no program break.

Anonymous `mmap` (`0x20`) ignores a non-zero address hint. The protection may be read, write, or both. Executable is rejected, and every anonymous page is non-executable. The call reserves the range and records it. It does not allocate physical frames. Each record is a node from the kernel heap, so the process holds as many ranges as that heap can allocate. A range runs until it meets the end of the image. `munmap` (`0x21`) removes one whole range that `mmap` or `map_file` handed out, and frees the node. Physical frames are freed only for pages that were actually touched.

`map_file` (`0x22`) allocates during the call. It reserves a range the same way `mmap` does, then copies a `/tmp` file into private pages. A later write to the file does not change the mapping, and closing the file leaves the mapping in place. An initramfs file cannot be mapped. Its bytes are the archive itself. See [Files](files.md). The copy stops when `pmm.alloc` cannot hand out another physical frame. An anonymous mapping hits that same limit when a reserved page is first touched.

Each thread gets a user stack of 16 pages, mapped at creation, with an unmapped guard page below it. Further threads take the next slot down. A fault on the guard ends the process.

## A fault in a fresh mapping

The page-fault gate runs on an interrupt stack with interrupts off. For a user access that is a not-present fault, and not an instruction fetch, `fillUserPage` looks the address up in the process's map list.

- The address is outside every reservation, or it is a stack guard: the process exits with status 142 (128 plus vector 14).
- The access is a write and the reservation is read-only: the same exit.
- The page is already present: the fault returns and the instruction runs again.
- Otherwise `pmm.alloc` returns one zeroed physical frame. It is mapped non-executable, and the instruction runs again.

A kernel fault is fatal. A fault on a kernel-stack guard page is reported as an overflow.

A copy between user memory and the kernel fills the same holes, so the program does not have to fault them in first. `copyToUser` and `copyFromUser` walk a page at a time. A page that is already present and usable is copied. A hole is filled, and the copy retries. The retry budget is the number of pages the range spans, plus one. A page that cannot be filled stops the walk, so neighboring holes stay unallocated. If the first page fails, the call returns an error. If some bytes were already copied, it returns that count.

## Where to read

- `kernel/src/mm/pmm.zig`, `kernel/src/mm/vmm.zig`, `kernel/src/mm/heap.zig`, `kernel/src/mm/heap_core.zig`, `kernel/src/mm/frame.zig`
- `kernel/src/lib/mem.zig`, `kernel/src/lib/virt.zig`
- `kernel/src/sched/aspace.zig`, `kernel/src/sched/maplist.zig`
- `kernel/src/sys/elf.zig` for the user-range constants
- The fault gate is `kernel/src/sys/ivt.zig`

Previous: [Boot](boot.md). Next: [The CPU](cpu.md).
