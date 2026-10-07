const lib = @import("lib");
const sys = lib.sys;

// uptime steps by 1 ms. The calibration window makes one tick a small
// fraction of the result, and each timed batch has to clear several ticks.
const cal_ns: u64 = 100_000_000;
const min_ns: u64 = 50_000_000;
const max_spins: u64 = 100_000;
const max_n: u64 = 1 << 30;

const page: usize = 4096;
const bytes: usize = 32 * page;
// The pipe ring leaves one slot empty, so a full message is a page minus one.
const pipe_full: usize = page - 1;

const Cal = struct {
    cycles: u64,
    ns: u64,
};

var pipe_wr: u64 = 0;
var pipe_rd: u64 = 0;
var pipe_size: usize = 1;
var pipe_msg: [page]u8 = @splat(1);

var spawn_path: []const u8 = "/echo";
var spawn_wr: u64 = 0;
var spawn_rd: u64 = 0;

var file_fd: u64 = 0;

fn rdtsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile (
        \\rdtsc
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

// (a * b) / den without a u128 divide. Userspace does not link compiler-rt.
fn mulDiv(a: u64, b: u64, den: u64) u64 {
    if (den == 0) return 0;
    const q = a / den;
    const r = a % den;
    return q * b + (r * b) / den;
}

fn fail(msg: []const u8) u64 {
    lib.eprint("bench: ");
    lib.eprint(msg);
    lib.eprint("\n");
    return 1;
}

fn calibrate() ?Cal {
    const t0 = sys.uptime();
    const c0 = rdtsc();
    var still: u64 = 0;
    var ns: u64 = 0;
    while (ns < cal_ns) {
        const t1 = sys.uptime();
        if (t1 < t0) return null;
        // One tick is many calls. Give up only when a reading never changes.
        if (t1 == t0 + ns) {
            still += 1;
            if (still == max_spins) return null;
        } else {
            still = 0;
        }
        ns = t1 - t0;
    }
    const cycles = rdtsc() -% c0;
    if (cycles == 0) return null;
    return .{ .cycles = cycles, .ns = ns };
}

fn printRow(name: []const u8, n: u64, cycles: u64, elapsed: u64, cal: Cal) void {
    const total = mulDiv(cycles, cal.ns, cal.cycles);
    lib.print(name);
    lib.print(" ");
    lib.printU64(n);
    lib.print(" ");
    lib.printU64(total);
    lib.print(" ");
    lib.printU64((total + n / 2) / n);
    lib.print(" ");
    lib.printU64((cycles + n / 2) / n);
    lib.print(" ");
    lib.printU64(elapsed / 1_000_000);
    lib.print("\n");
}

fn measureN(name: []const u8, cal: Cal, comptime once: fn () bool) u64 {
    var n: u64 = 1;
    while (true) {
        const t0 = sys.uptime();
        const c0 = rdtsc();
        var i: u64 = 0;
        var ok = true;
        while (i < n) : (i += 1) {
            if (!once()) {
                ok = false;
                break;
            }
        }
        const cycles = rdtsc() -% c0;
        if (!ok) return fail(name);
        const t1 = sys.uptime();
        if (t1 < t0) return fail("uptime did not advance");
        const elapsed = t1 - t0;
        if (elapsed >= min_ns) {
            printRow(name, n, cycles, elapsed, cal);
            return 0;
        }
        if (n > max_n / 2) return fail("uptime did not advance");
        n *= 2;
    }
}

fn onceEmpty() bool {
    // An empty body is deleted under -Doptimize=small.
    asm volatile ("" ::: .{ .memory = true });
    return true;
}

fn oncePid() bool {
    _ = sys.getpid();
    return true;
}

fn onceYield() bool {
    sys.yield();
    return true;
}

fn pipeChild() u64 {
    var buf: [page]u8 = undefined;
    while (true) {
        const n = sys.read(0, &buf);
        if (n < 0) return 1;
        if (n == 0) return 0;
        if (sys.writeAll(1, buf[0..@intCast(n)]) < 0) return 1;
    }
}

fn pipeOnce() bool {
    if (sys.writeAll(pipe_wr, pipe_msg[0..pipe_size]) < 0) return false;
    var got: usize = 0;
    while (got < pipe_size) {
        const n = sys.read(pipe_rd, pipe_msg[got..pipe_size]);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

fn pipes(cal: Cal) u64 {
    var down: [2]i64 = undefined;
    var up: [2]i64 = undefined;
    if (sys.pipe(&down) < 0) return fail("pipe");
    if (sys.pipe(&up) < 0) {
        _ = sys.close(@intCast(down[0]));
        _ = sys.close(@intCast(down[1]));
        return fail("pipe");
    }
    const argv = [_][]const u8{ "/bench", "child" };
    const pid = sys.spawn("/bench", &argv, @intCast(down[0]), @intCast(up[1]), 2);
    _ = sys.close(@intCast(down[0]));
    _ = sys.close(@intCast(up[1]));
    if (pid < 0) {
        _ = sys.close(@intCast(down[1]));
        _ = sys.close(@intCast(up[0]));
        return fail("pipe");
    }
    pipe_wr = @intCast(down[1]);
    pipe_rd = @intCast(up[0]);
    // Let the child block in read before the timed loop.
    sys.yield();

    const rows = [_]struct { n: usize, name: []const u8 }{
        .{ .n = 1, .name = "pipe1" },
        .{ .n = pipe_full, .name = "pipe4095" },
    };
    var rc: u64 = 0;
    for (rows) |row| {
        if (rc != 0) break;
        pipe_size = row.n;
        rc = measureN(row.name, cal, pipeOnce);
    }
    _ = sys.close(pipe_wr);
    _ = sys.wait(@intCast(pid));
    _ = sys.close(pipe_rd);
    return rc;
}

fn spawnOnce() bool {
    const argv = [_][]const u8{spawn_path};
    const pid = sys.spawn(spawn_path, &argv, 0, spawn_wr, 2);
    if (pid < 0) return false;
    if (sys.wait(@intCast(pid)) < 0) return false;
    var buf: [8]u8 = undefined;
    return sys.read(spawn_rd, &buf) > 0;
}

fn copyFile(src_path: []const u8, dst_path: []const u8) bool {
    const src = sys.open(src_path);
    if (src < 0) return false;
    const dst = sys.openAt(dst_path, sys.open_write | sys.open_create);
    if (dst < 0) {
        _ = sys.close(@intCast(src));
        return false;
    }
    const rc = lib.copyFd(@intCast(src), @intCast(dst));
    _ = sys.close(@intCast(src));
    _ = sys.close(@intCast(dst));
    return rc == 0;
}

fn spawns(cal: Cal) u64 {
    var sink: [2]i64 = undefined;
    if (sys.pipe(&sink) < 0) return fail("spawn");
    spawn_rd = @intCast(sink[0]);
    spawn_wr = @intCast(sink[1]);
    spawn_path = "/echo";
    var rc = measureN("spawn", cal, spawnOnce);
    if (rc == 0) {
        if (!copyFile("/echo", "/tmp/echo")) {
            rc = fail("spawn");
        } else {
            spawn_path = "/tmp/echo";
            rc = measureN("spawntmp", cal, spawnOnce);
            _ = sys.unlink("/tmp/echo");
        }
    }
    _ = sys.close(spawn_wr);
    _ = sys.close(spawn_rd);
    return rc;
}

fn writeBytes(fd: u64, len: usize) bool {
    var buf: [page]u8 = @splat(0x5a);
    var left = len;
    while (left > 0) {
        const n = @min(buf.len, left);
        if (sys.writeAll(fd, buf[0..n]) < 0) return false;
        left -= n;
    }
    return true;
}

fn readOnce() bool {
    if (sys.lseek(file_fd, 0, sys.seek_set) < 0) return false;
    var got: usize = 0;
    var buf: [page]u8 = undefined;
    while (got < bytes) {
        const n = sys.read(file_fd, &buf);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

fn touch(addr: usize, len: usize) void {
    var off: usize = 0;
    while (off < len) : (off += page) {
        const p: *volatile u8 = @ptrFromInt(addr + off);
        _ = p.*;
    }
}

fn mapOnce() bool {
    const addr = sys.mapFile(file_fd, bytes, sys.prot_read);
    if (addr < 0) return false;
    touch(@intCast(addr), bytes);
    return sys.munmap(@intCast(addr), bytes) == 0;
}

fn files(cal: Cal) u64 {
    const created = sys.openAt("/tmp/bench.dat", sys.open_write | sys.open_create);
    if (created < 0) return fail("read");
    const wrote = writeBytes(@intCast(created), bytes);
    _ = sys.close(@intCast(created));
    if (!wrote) {
        _ = sys.unlink("/tmp/bench.dat");
        return fail("read");
    }
    const fd = sys.open("/tmp/bench.dat");
    if (fd < 0) {
        _ = sys.unlink("/tmp/bench.dat");
        return fail("read");
    }
    file_fd = @intCast(fd);
    var rc = measureN("read", cal, readOnce);
    if (rc == 0) rc = measureN("map", cal, mapOnce);
    _ = sys.close(file_fd);
    _ = sys.unlink("/tmp/bench.dat");
    return rc;
}

fn pageUp(addr: usize) usize {
    return (addr + page - 1) & ~(page - 1);
}

fn brkOnce() bool {
    const cur = sys.brk(0);
    if (cur < 0) return false;
    const old: usize = @intCast(cur);
    const start = pageUp(old);
    if (sys.brk(start + bytes) < 0) return false;
    touch(start, bytes);
    return sys.brk(old) >= 0;
}

fn mmapOnce() bool {
    const addr = sys.mmap(0, bytes, sys.prot_read | sys.prot_write);
    if (addr < 0) return false;
    touch(@intCast(addr), bytes);
    return sys.munmap(@intCast(addr), bytes) == 0;
}

pub fn main(argv: []const []const u8) u64 {
    if (argv.len > 1 and lib.eql(argv[1], "child")) return pipeChild();

    const cal = calibrate() orelse return fail("uptime did not advance");
    lib.print("cycles/ms ");
    lib.printU64(mulDiv(cal.cycles, 1_000_000, cal.ns));
    lib.print("\n");
    lib.print("name count total_ns per_ns cyc ms\n");
    if (measureN("empty", cal, onceEmpty) != 0) return 1;
    if (measureN("getpid", cal, oncePid) != 0) return 1;
    if (measureN("yield", cal, onceYield) != 0) return 1;
    if (pipes(cal) != 0) return 1;
    if (spawns(cal) != 0) return 1;
    if (files(cal) != 0) return 1;
    if (measureN("brk", cal, brkOnce) != 0) return 1;
    if (measureN("mmap", cal, mmapOnce) != 0) return 1;
    return 0;
}
