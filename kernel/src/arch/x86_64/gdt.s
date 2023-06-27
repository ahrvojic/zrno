.global load_gdt
.type load_gdt, @function
load_gdt:
    lgdt (gdtr)
.reload_segments:
    pushq kernel_code_seg
    leaq .reload_cs, %rax
    pushq %rax
    lretq
.reload_cs:
    movw kernel_data_seg, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    ret

.global load_tss
.type load_tss, @function
load_tss:
    ltr tss_seg
    ret
