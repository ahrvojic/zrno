/* Userspace ET_EXEC. Null load: #PF must kill this process, not the kernel. */
        .code64
        .section .text
        .global _start
_start:
        movq $1, %rax
        movq $1, %rdi
        leaq msg(%rip), %rsi
        movq $msg_len, %rdx
        int $0x80

        xorq %rax, %rax
        movq (%rax), %rbx

        movq $2, %rax
        movq $1, %rdi
        int $0x80

        .section .rodata
msg:
        .ascii "faulting...\n"
        .equ msg_len, . - msg
