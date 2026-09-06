pub const page_size: usize = 4096;
/// Exclusive end of the canonical user half (PML4[256] is kernel).
pub const user_space_end: usize = 0x0000_8000_0000_0000;
