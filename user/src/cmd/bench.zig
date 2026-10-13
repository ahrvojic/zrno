const lib = @import("lib");
const sys = lib.sys;

// uptime is nanoseconds when the TSC rate is known, and 1 ms ticks
// otherwise. The windows stay well above one tick.
const cal_ns: u64 = 100_000_000;
const min_ns: u64 = 50_000_000;
const max_spins: u64 = 100_000;
const max_n: u64 = 1 << 30;

const page: usize = 4096;
const bytes: usize = 32 * page;
// The pipe ring leaves one slot empty, so a full message is a page minus one.
const pipe_full: usize = page - 1;
// One mebibyte, off the 64 KiB user stack. Fault it in before the timer.
const stream_len: usize = 256 * page;

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
var stream_addr: usize = 0;

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
    printTable();
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

// A u64 is at most 20 digits, and each title is shorter than that.
const spaces = "                    ";
// Syscall rows, then the spin, busy, and stream pairs.
const max_rows = 24;

const h_name = "name";
const h_count = "count";
const h_total = "total_ns";
const h_per = "per_ns";
const h_cyc = "cyc";
const h_ms = "ms";

const Row = struct {
    name: []const u8,
    n: u64,
    total: u64,
    per: u64,
    cyc: u64,
    ms: u64,
};

var saved: [max_rows]Row = undefined;
var saved_len: usize = 0;

fn digits(v: u64) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

fn printPad(width: usize, len: usize) void {
    if (len < width) lib.print(spaces[0 .. width - len]);
}

fn printLeft(text: []const u8, width: usize) void {
    lib.print(text);
    printPad(width, text.len);
}

fn printRight(text: []const u8, width: usize) void {
    printPad(width, text.len);
    lib.print(text);
}

fn printNum(v: u64, width: usize) void {
    printPad(width, digits(v));
    lib.printU64(v);
}

fn printRow(name: []const u8, n: u64, cycles: u64, elapsed: u64, cal: Cal) void {
    if (saved_len == saved.len) return;
    const total = mulDiv(cycles, cal.ns, cal.cycles);
    saved[saved_len] = .{
        .name = name,
        .n = n,
        .total = total,
        .per = (total + n / 2) / n,
        .cyc = (cycles + n / 2) / n,
        .ms = elapsed / 1_000_000,
    };
    saved_len += 1;
}

fn printTable() void {
    if (saved_len == 0) return;
    const rows = saved[0..saved_len];
    var w_name: usize = h_name.len;
    var w_count: usize = h_count.len;
    var w_total: usize = h_total.len;
    var w_per: usize = h_per.len;
    var w_cyc: usize = h_cyc.len;
    var w_ms: usize = h_ms.len;
    for (rows) |r| {
        w_name = @max(w_name, r.name.len);
        w_count = @max(w_count, digits(r.n));
        w_total = @max(w_total, digits(r.total));
        w_per = @max(w_per, digits(r.per));
        w_cyc = @max(w_cyc, digits(r.cyc));
        w_ms = @max(w_ms, digits(r.ms));
    }

    printLeft(h_name, w_name);
    lib.print(" ");
    printRight(h_count, w_count);
    lib.print(" ");
    printRight(h_total, w_total);
    lib.print(" ");
    printRight(h_per, w_per);
    lib.print(" ");
    printRight(h_cyc, w_cyc);
    lib.print(" ");
    printRight(h_ms, w_ms);
    lib.print("\n");

    for (rows) |r| {
        printLeft(r.name, w_name);
        lib.print(" ");
        printNum(r.n, w_count);
        lib.print(" ");
        printNum(r.total, w_total);
        lib.print(" ");
        printNum(r.per, w_per);
        lib.print(" ");
        printNum(r.cyc, w_cyc);
        lib.print(" ");
        printNum(r.ms, w_ms);
        lib.print("\n");
    }
    saved_len = 0;
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

fn readFull(fd: u64, buf: []u8) i64 {
    var got: usize = 0;
    while (got < buf.len) {
        const n = sys.read(fd, buf[got..]);
        if (n < 0) return n;
        if (n == 0) return @intCast(got);
        got += @intCast(n);
    }
    return @intCast(got);
}

fn closeQuiet(fd: *i64) void {
    if (fd.* < 0) return;
    _ = sys.close(@intCast(fd.*));
    fd.* = -1;
}

// User mode only. A syscall holds the one kernel lock, so the other core
// cannot run the same work.
fn spinCycles(n: u64) void {
    const start = rdtsc();
    while (rdtsc() -% start < n) {
        asm volatile ("" ::: .{ .memory = true });
    }
}

// `test` reads both words and writes neither, so a pure loop cannot cross
// this point. An empty asm did not keep the result live under -Doptimize=small.
fn pin(v: u64, other: u64) u64 {
    asm volatile ("test %[v], %[other]"
        :
        : [v] "r" (v),
          [other] "r" (other),
        : .{ .cc = true, .memory = true });
    return v;
}

fn spinWork(n: u64) u64 {
    spinCycles(n);
    return 0;
}

// Fixed steps. Sampling the TSC would time the clock, not the work.
fn busyWork(n: u64) u64 {
    var x: u64 = 0x9E3779B97F4A7C15;
    for (0..n) |i| {
        x *%= 0x9E3779B97F4A7C15;
        x +%= i;
        x ^= x >> 30;
    }
    return x;
}

// One pass reads `stream_len` bytes. The pages are already resident.
fn streamWork(n: u64) u64 {
    const p: [*]volatile u64 = @ptrFromInt(stream_addr);
    var sum: u64 = 0;
    for (0..n) |_| {
        for (0..stream_len / @sizeOf(u64)) |i| sum +%= p[i];
    }
    return sum;
}

// A fault takes the kernel lock, so it happens before the timer.
fn mapStream() bool {
    const addr = sys.mmap(0, stream_len, sys.prot_read | sys.prot_write);
    if (addr < 0) return false;
    stream_addr = @intCast(addr);
    for (0..stream_len / page) |i| {
        const p: *volatile u8 = @ptrFromInt(stream_addr + i * page);
        p.* = 1;
    }
    return true;
}

fn unmapStream() void {
    _ = sys.munmap(stream_addr, stream_len);
}

fn twoCores() ?bool {
    const need = @sizeOf(sys.MachineInfo) + 2 * @sizeOf(sys.CoreInfo);
    var buf: [need]u8 = undefined;
    const n = sys.cores(&buf);
    if (n < 0) return null;
    return n >= need;
}

// Ready byte, then one native-endian count. The ack is the low byte of
// the result, so the write keeps the work.
fn peerChild(comptime work: fn (u64) u64) u64 {
    const ready = [_]u8{1};
    if (sys.writeAll(1, &ready) < 0) return 1;
    var raw: [8]u8 = undefined;
    const n = readFull(0, &raw);
    if (n != raw.len) return 1;
    const ack = [_]u8{@truncate(work(@bitCast(raw)))};
    if (sys.writeAll(1, &ack) < 0) return 1;
    return 0;
}

fn streamChild() u64 {
    if (!mapStream()) return 1;
    return peerChild(streamWork);
}

fn timedRow(name: []const u8, count: u64, cal: Cal, t0: u64, c0: u64) u64 {
    const cyc = rdtsc() -% c0;
    const t1 = sys.uptime();
    if (t1 < t0) return fail("uptime did not advance");
    printRow(name, count, cyc, t1 - t0, cal);
    return 0;
}

// Double until the window reaches `min_ns`. Returns the step count a peer
// repeats. The row's count is `n * unit`.
fn measureUnits(name: []const u8, cal: Cal, unit: u64, comptime work: fn (u64) u64) ?u64 {
    var n: u64 = 1;
    while (true) {
        const t0 = sys.uptime();
        var stamp = rdtsc();
        const result = work(pin(n, stamp));
        stamp = pin(stamp, result);
        const cycles = rdtsc() -% stamp;
        const t1 = sys.uptime();
        if (t1 < t0) return null;
        const elapsed = t1 - t0;
        if (elapsed >= min_ns) {
            printRow(name, n * unit, cycles, elapsed, cal);
            return n;
        }
        if (n > max_n / 2) return null;
        n *= 2;
    }
}

// Parent and child. `down` is parent to child. `up` carries the ready byte
// and the ack.
const Peer = struct {
    down: [2]i64 = @splat(-1),
    up: [2]i64 = @splat(-1),
    pid: i64 = -1,

    fn deinit(self: *Peer) void {
        closeQuiet(&self.down[0]);
        closeQuiet(&self.up[1]);
        closeQuiet(&self.down[1]);
        closeQuiet(&self.up[0]);
        if (self.pid >= 0) _ = sys.wait(@intCast(self.pid));
    }

    fn start(self: *Peer, mode: []const u8) bool {
        if (sys.pipe(&self.down) < 0 or sys.pipe(&self.up) < 0) return false;
        const argv = [_][]const u8{ "/bench", mode };
        self.pid = sys.spawn("/bench", &argv, @intCast(self.down[0]), @intCast(self.up[1]), 2);
        closeQuiet(&self.down[0]);
        closeQuiet(&self.up[1]);
        if (self.pid < 0) return false;
        var byte: [1]u8 = undefined;
        return sys.read(@intCast(self.up[0]), &byte) == 1;
    }

    fn exchange(self: *Peer, n: u64, comptime work: fn (u64) u64) bool {
        var raw: [8]u8 = @bitCast(n);
        if (sys.writeAll(@intCast(self.down[1]), &raw) != 0) return false;
        // The write clobbers memory, so this reload stays after it.
        const steps: u64 = @bitCast(raw);
        const result = work(steps);
        _ = pin(result, steps);
        var byte: [1]u8 = undefined;
        return sys.read(@intCast(self.up[0]), &byte) == 1;
    }
};

fn timeSpin(cal: Cal, cycles: u64) u64 {
    const t0 = sys.uptime();
    const c0 = rdtsc();
    spinCycles(cycles);
    return timedRow("spin", 1, cal, t0, c0);
}

// Spawn and the ready byte stay outside the window. The write end is
// closed before `wait`. `count` is the work of both sides.
fn timePeer(name: []const u8, mode: []const u8, count: u64, n: u64, cal: Cal, comptime work: fn (u64) u64) u64 {
    var peer: Peer = .{};
    defer peer.deinit();
    if (!peer.start(mode)) return fail(name);
    const t0 = sys.uptime();
    const c0 = rdtsc();
    if (!peer.exchange(n, work)) return fail(name);
    return timedRow(name, count, cal, t0, c0);
}

// The 50 ms floor lets the idle core's timer pick up the child. One core
// skips every row here. A pair row's count is both sides.
fn multicore(cal: Cal) u64 {
    const two = twoCores() orelse return fail("cores");
    if (!two) return 0;
    const cycles = mulDiv(min_ns, cal.cycles, cal.ns);
    if (cycles == 0) return fail("spin");
    if (timeSpin(cal, cycles) != 0) return 1;
    if (timePeer("spin2", "spin", 1, cycles, cal, spinWork) != 0) return 1;

    const steps = measureUnits("busy", cal, 1, busyWork) orelse return fail("uptime did not advance");
    if (timePeer("busy2", "busy", steps * 2, steps, cal, busyWork) != 0) return 1;

    if (!mapStream()) return fail("stream");
    defer unmapStream();
    const unit: u64 = stream_len;
    const passes = measureUnits("stream", cal, unit, streamWork) orelse return fail("uptime did not advance");
    return timePeer("stream2", "stream", passes * unit * 2, passes, cal, streamWork);
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
    if (argv.len > 1) {
        if (lib.eql(argv[1], "child")) return pipeChild();
        if (lib.eql(argv[1], "spin")) return peerChild(spinWork);
        if (lib.eql(argv[1], "busy")) return peerChild(busyWork);
        if (lib.eql(argv[1], "stream")) return streamChild();
    }

    const cal = calibrate() orelse return fail("uptime did not advance");
    lib.print("cycles/ms ");
    lib.printU64(mulDiv(cal.cycles, 1_000_000, cal.ns));
    lib.print("\n");
    if (measureN("empty", cal, onceEmpty) != 0) return 1;
    if (measureN("getpid", cal, oncePid) != 0) return 1;
    if (measureN("yield", cal, onceYield) != 0) return 1;
    if (pipes(cal) != 0) return 1;
    if (spawns(cal) != 0) return 1;
    if (files(cal) != 0) return 1;
    if (measureN("brk", cal, brkOnce) != 0) return 1;
    if (measureN("mmap", cal, mmapOnce) != 0) return 1;
    if (multicore(cal) != 0) return 1;
    printTable();
    return 0;
}
