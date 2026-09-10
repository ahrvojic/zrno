pub const page_size: usize = 4096;
/// Exclusive end of user VA (4-level paging). Canonical lower half is
/// [0, 2^47); the last page is omitted so a SYSCALL on the last two bytes
/// cannot produce a non-canonical SYSRET RIP (Linux TASK_SIZE_MAX).
pub const user_space_end: usize = (1 << 47) - page_size;
