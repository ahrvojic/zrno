/* ELF64 / x86-64. The UEFI loader copies PT_LOAD and jumps to _start. */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

/* Kernel entry; exported from main.zig. BootInfo arrives in rdi. */
ENTRY(_start)

/* PT_LOAD p_flags describe the final permissions (PF_X=1, PF_W=2, PF_R=4).
 * The loader maps the image writable; vmm installs these splits. */
PHDRS
{
    text     PT_LOAD    FLAGS(0x05); /* PF_X | PF_R */
    rodata   PT_LOAD    FLAGS(0x04); /* PF_R */
    data     PT_LOAD    FLAGS(0x06); /* PF_W | PF_R */
}

SECTIONS
{
    /*
     * Higher half, at the start of the top 2GiB.
     * Zig's code_model=.kernel (signed 32-bit immediates) needs the whole
     * image inside that 2GiB window. The loader maps this address.
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
    } :data

    /* Last in :data so the file is not padded with BSS zeros (memsz > filesz). */
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    data_end_addr = .;

    /* Freestanding: no unwind tables, ELF notes, dynamic linker, or relocations. */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.hash)
        *(.gnu.hash)
        *(.got)
        *(.got.plt)
        *(.rela*)
        *(.rel*)
    }
}
