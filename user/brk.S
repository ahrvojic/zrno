/* Userspace ET_EXEC. Syscall numbers match kernel/src/sys/syscall.zig
   (write=1, exit=2, brk=13). */
        .code64
        .section .text
        .global _start
_start:
        /* Query. */
        movq $13, %rax
        xorq %rdi, %rdi
        int $0x80
        testq %rax, %rax
        jle fail
        movq %rax, %rbx

        /* Below image end is EINVAL. */
        leaq -1(%rbx), %rdi
        movq $13, %rax
        int $0x80
        testq %rax, %rax
        jns fail

        /* Same-page grow, then store. */
        leaq 1(%rbx), %rdi
        movq $13, %rax
        int $0x80
        cmpq %rdi, %rax
        jne fail
        cmpb $0, (%rbx)
        jne fail
        movb $0xa5, (%rbx)
        cmpb $0xa5, (%rbx)
        jne fail

        /* Two more pages. */
        leaq 0x2000(%rbx), %r12
        movq %r12, %rdi
        movq $13, %rax
        int $0x80
        cmpq %r12, %rax
        jne fail
        movb $0x5a, 0x1000(%rbx)
        cmpb $0x5a, 0x1000(%rbx)
        jne fail
        movb $0x3c, 0x1fff(%rbx)
        cmpb $0x3c, 0x1fff(%rbx)
        jne fail

        /* Over the 32 MiB cap is ENOMEM. */
        movabsq $0x2100000, %rdi
        addq %rbx, %rdi
        movq $13, %rax
        int $0x80
        testq %rax, %rax
        jns fail

        /* Shrink back to the original break. */
        movq %rbx, %rdi
        movq $13, %rax
        int $0x80
        cmpq %rbx, %rax
        jne fail
        xorq %rdi, %rdi
        movq $13, %rax
        int $0x80
        cmpq %rbx, %rax
        jne fail

        movq $1, %rax
        movq $1, %rdi
        leaq okmsg(%rip), %rsi
        movq $ok_len, %rdx
        int $0x80
        movq $2, %rax
        xorq %rdi, %rdi
        int $0x80

fail:
        movq $1, %rax
        movq $1, %rdi
        leaq failmsg(%rip), %rsi
        movq $fail_len, %rdx
        int $0x80
        movq $2, %rax
        movq $1, %rdi
        int $0x80

        .section .rodata
okmsg:
        .ascii "brk ok\n"
        .equ ok_len, . - okmsg
failmsg:
        .ascii "brk fail\n"
        .equ fail_len, . - failmsg
