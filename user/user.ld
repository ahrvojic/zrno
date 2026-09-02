/* ELF64 / x86-64 ET_EXEC. Fixed load address; no PT_INTERP, no PIE. */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

ENTRY(_start)

/* PT_LOAD p_flags: PF_X=1, PF_W=2, PF_R=4. */
PHDRS
{
    text   PT_LOAD FLAGS(0x05); /* PF_X | PF_R */
    rodata PT_LOAD FLAGS(0x04); /* PF_R */
}

SECTIONS
{
    . = 0x400000;

    .text : {
        *(.text .text.*)
    } :text

    /* Page-align so RX and R never share a mapping. */
    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.rela.*)
        *(.gnu.*)
        *(.got*)
    }
}
