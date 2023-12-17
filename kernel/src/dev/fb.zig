const limine = @import("limine");

const debug = @import("../sys/debug.zig");
const font = @import("font.zig");

pub fn init(fb_res: *limine.FramebufferResponse) !void {
    if (fb_res.framebuffer_count < 1) {
        debug.panic("No framebuffer available!");
    }

    const fb = fb_res.framebuffers()[0];
    _ = fb; // TODO
}
