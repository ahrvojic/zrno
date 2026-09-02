//! Limine boot protocol types used by this kernel (base revision 6).
//! Layouts follow the official protocol header.

inline fn id(a: u64, b: u64) [4]u64 {
    return .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b };
}

pub const RequestsStartMarker = extern struct {
    marker: [4]u64 = .{
        0xf6b8f4b39de7d1ae,
        0xfab91a6940fcb9cf,
        0x785c6ed015d3e316,
        0x181e920a7852b9d9,
    },
};

pub const RequestsEndMarker = extern struct {
    marker: [2]u64 = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 },
};

pub const BaseRevision = extern struct {
    id: [2]u64 = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },
    revision: u64,

    pub fn isSupported(self: *const volatile BaseRevision) bool {
        return self.revision == 0;
    }
};

pub const BootloaderInfoResponse = extern struct {
    revision: u64,
    name: [*:0]u8,
    version: [*:0]u8,
};

pub const BootloaderInfoRequest = extern struct {
    id: [4]u64 = id(0xf55038d8e2a1202f, 0x279426fcf5f59740),
    revision: u64 = 0,
    response: ?*BootloaderInfoResponse = null,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = id(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

pub const FramebufferMemoryModel = enum(u8) {
    rgb = 1,
    _,
};

pub const VideoMode = extern struct {
    pitch: u64,
    width: u64,
    height: u64,
    bpp: u16,
    memory_model: FramebufferMemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: FramebufferMemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?[*]u8,
    mode_count: u64,
    modes: [*]*VideoMode,

    pub fn data(self: *Framebuffer) []u8 {
        return self.address[0 .. self.pitch * self.height];
    }
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers_ptr: [*]*Framebuffer,

    pub fn framebuffers(self: *FramebufferResponse) []*Framebuffer {
        return self.framebuffers_ptr[0..self.framebuffer_count];
    }
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = id(0x9d5827dcd881dd75, 0xa3148604f6fab11b),
    revision: u64 = 1,
    response: ?*FramebufferResponse = null,
};

pub const MemoryMapEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    reserved_mapped = 8,

    /// Regions the bootloader maps into the HHDM at base revision 6.
    pub fn inHhdm(self: MemoryMapEntryType) bool {
        return switch (self) {
            .usable,
            .bootloader_reclaimable,
            .executable_and_modules,
            .framebuffer,
            .acpi_reclaimable,
            .acpi_nvs,
            .reserved_mapped,
            => true,
            .reserved, .bad_memory => false,
        };
    }
};

pub const MemoryMapEntry = extern struct {
    base: u64,
    length: u64,
    kind: MemoryMapEntryType,
};

pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries_ptr: [*]*MemoryMapEntry,

    pub fn entries(self: *MemoryMapResponse) []*MemoryMapEntry {
        return self.entries_ptr[0..self.entry_count];
    }
};

pub const MemoryMapRequest = extern struct {
    id: [4]u64 = id(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
    revision: u64 = 0,
    response: ?*MemoryMapResponse = null,
};

pub const RsdpResponse = extern struct {
    revision: u64,
    address: *anyopaque,
};

pub const RsdpRequest = extern struct {
    id: [4]u64 = id(0xc5e77b6b397e7b43, 0x27637845accdcf3c),
    revision: u64 = 0,
    response: ?*RsdpResponse = null,
};

pub const ExecutableAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const ExecutableAddressRequest = extern struct {
    id: [4]u64 = id(0x71ba76863cc55f63, 0xb2644a48c516a487),
    revision: u64 = 0,
    response: ?*ExecutableAddressResponse = null,
};

pub const Uuid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

pub const File = extern struct {
    revision: u64,
    address: [*]u8,
    size: u64,
    path: [*:0]u8,
    string: [*:0]u8,
    media_type: u32,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: Uuid,
    gpt_part_uuid: Uuid,
    part_uuid: Uuid,
};

pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules_ptr: [*]*File,

    pub fn modules(self: *ModuleResponse) []*File {
        return self.modules_ptr[0..self.module_count];
    }
};

pub const ModuleRequest = extern struct {
    id: [4]u64 = id(0x3e7e279702be32af, 0xca1c4f3bd1280cee),
    revision: u64 = 0,
    response: ?*ModuleResponse = null,
};
