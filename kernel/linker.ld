/* ELF64 / x86-64; Limine loads ELF. */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

/* Kernel entry; exported from main.zig. */
ENTRY(_start)

/* PT_LOAD p_flags are the MMU permissions Limine installs (PF_X=1, PF_W=2, PF_R=4). */
PHDRS
{
    text     PT_LOAD    FLAGS(0x05); /* PF_X | PF_R */
    rodata   PT_LOAD    FLAGS(0x04); /* PF_R */
    data     PT_LOAD    FLAGS(0x06); /* PF_W | PF_R */
    dynamic  PT_DYNAMIC FLAGS(0x06); /* PIE relocations (pic = true in build.zig) */
}

SECTIONS
{
    /*
     * Higher half, at the start of the top 2GiB.
     * Limine requires load addresses >= 0xffffffff80000000, and Zig's
     * code_model=.kernel (signed 32-bit immediates) needs the whole image
     * inside that 2GiB window.
     */
    . = 0xffffffff80000000;

    /* Bounds used by vmm.mapKernelSection and panic stack traces. */
    text_start_addr = .;

    .text : {
        *(.text .text.*)
    } :text

    text_end_addr = .;

    /* Page-align so RX and R segments never share a mapping. */
    . = ALIGN(CONSTANT(MAXPAGESIZE));

    rodata_start_addr = .;

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    rodata_end_addr = .;

    /* Page-align so R and RW segments never share a mapping. */
    . = ALIGN(CONSTANT(MAXPAGESIZE));

    data_start_addr = .;

    .data : {
        *(.data .data.*)

        /* Limine scans these for request magics and writes response pointers.
         * KEEP so section GC cannot drop the markers. */
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :data

    /* PT_DYNAMIC for Limine's PIE relocator; also part of the RW load segment. */
    .dynamic : {
        *(.dynamic)
    } :data :dynamic

    /* Last in :data so the file is not padded with BSS zeros (memsz > filesz). */
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    data_end_addr = .;

    /* Freestanding: no unwind tables, ELF notes, or PT_INTERP dynamic linker. */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.interp)
    }
}
