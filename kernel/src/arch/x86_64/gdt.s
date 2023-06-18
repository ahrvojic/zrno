.type load_gdt, @function
load_gdt:
    lgdt (%rdi) // first parameter is gdtr struct address

.reload_segments:
    pushq $0x08 // kernel code segment
    leaq .reload_cs, %rax
    pushq %rax
    lretq

.reload_cs:
    movw $0x10, %ax // kernel data segment
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    ret
