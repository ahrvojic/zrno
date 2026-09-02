/* Userspace ET_EXEC. Syscall numbers match kernel/src/sys/syscall.zig (write=1, exit=2). */
        .code64
        .section .text
        .global _start
_start:
        movq $1, %rax
        movq $1, %rdi
        leaq msg(%rip), %rsi
        movq $msg_len, %rdx
        int $0x80

        movq $2, %rax
        xorq %rdi, %rdi
        int $0x80

        .section .rodata
msg:
        .ascii "Hello from userspace!\n"
        .equ msg_len, . - msg
