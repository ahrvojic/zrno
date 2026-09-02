/* Userspace ET_EXEC. Syscall numbers match kernel/src/sys/syscall.zig (exec=7, exit=2). */
        .code64
        .section .text
        .global _start
_start:
        movq $7, %rax
        leaq path(%rip), %rdi
        int $0x80

        movq $2, %rax
        xorq %rdi, %rdi
        int $0x80

        .section .rodata
path:
        .asciz "/hello"
