const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));
const huge_alloc = @import("huge_alloc");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Timer = std.time.Timer;
const sort = std.sort;
const doNotOptimizeAway = std.mem.doNotOptimizeAway;

const NUM_THREADS = 10;

pub fn main() !void {
    var huge_allocators: [NUM_THREADS]huge_alloc.HugePageAlloc = undefined;
    var huge_alloc_allocs: [NUM_THREADS]Allocator = undefined;

    for (0..NUM_THREADS) |i| {
        huge_allocators[i] = huge_alloc.HugePageAlloc.init(.{});
        huge_alloc_allocs[i] = huge_allocators[i].allocator();
    }

    defer for (&huge_allocators) |*a| {
        a.deinit();
    };

    var huge_2mb_allocators: [NUM_THREADS]huge_alloc.HugePageAlloc = undefined;
    var huge_2mb_alloc_allocs: [NUM_THREADS]Allocator = undefined;

    for (0..NUM_THREADS) |i| {
        huge_2mb_allocators[i] = huge_alloc.HugePageAlloc.init(.{ .page_alloc_vtable = huge_alloc.huge_page_2mb_alloc_vtable });
        huge_2mb_alloc_allocs[i] = huge_2mb_allocators[i].allocator();
    }

    defer for (&huge_2mb_allocators) |*a| {
        a.deinit();
    };

    var huge_1gb_allocators: [NUM_THREADS]huge_alloc.HugePageAlloc = undefined;
    var huge_1gb_alloc_allocs: [NUM_THREADS]Allocator = undefined;

    for (0..NUM_THREADS) |i| {
        huge_1gb_allocators[i] = huge_alloc.HugePageAlloc.init(.{ .page_alloc_vtable = huge_alloc.huge_page_1gb_alloc_vtable });
        huge_1gb_alloc_allocs[i] = huge_1gb_allocators[i].allocator();
    }

    defer for (&huge_1gb_allocators) |*a| {
        a.deinit();
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    var args = std.process.args();
    _ = args.next() orelse unreachable;

    const alloc_name = args.next() orelse @panic("alloc_name argument not found");
    const buf_size_str = args.next() orelse @panic("buf_size argument not found");
    const buf_size = try std.fmt.parseInt(usize, buf_size_str, 10);
    const mem_use_str = args.next() orelse @panic("mem_size argument not found");
    const mem_use = try std.fmt.parseInt(usize, mem_use_str, 10);
    const num_runs_str = args.next() orelse @panic("num_runs argument not found");
    const num_runs = try std.fmt.parseInt(usize, num_runs_str, 10);

    var use_arena: bool = undefined;
    var allocs: [NUM_THREADS]Allocator = undefined;

    if (std.mem.eql(u8, alloc_name, "huge_alloc")) {
        allocs = huge_alloc_allocs;
        use_arena = false;
    } else if (std.mem.eql(u8, alloc_name, "page_alloc")) {
        allocs = .{std.heap.page_allocator} ** NUM_THREADS;
        use_arena = true;
    } else if (std.mem.eql(u8, alloc_name, "general_purpose_alloc")) {
        allocs = .{gpa_alloc} ** NUM_THREADS;
        use_arena = true;
    } else if (std.mem.eql(u8, alloc_name, "huge_2mb_alloc")) {
        allocs = huge_2mb_alloc_allocs;
        use_arena = false;
    } else if (std.mem.eql(u8, alloc_name, "huge_1gb_alloc")) {
        allocs = huge_1gb_alloc_allocs;
        use_arena = false;
    } else {
        @panic("unknown alloc name");
    }

    runBench(&Bench{
        .name = alloc_name,
        .allocs = allocs,
        .num_runs = num_runs,
        .buf_size = buf_size,
        .num_bufs = mem_use / buf_size / 8 / 3 / NUM_THREADS,
        .use_arena = use_arena,
    }) catch {
        std.debug.print("Failed to run {s} with buf_size = {d}\n", .{ alloc_name, buf_size });
    };
}

//fn next_power_of_two(comptime T: type, val: T) T {
//    return std.math.shl(T, 1, (@typeInfo(T).int.bits - @clz(val -% @as(T, 1))));
//}

const Bench = struct {
    name: []const u8,
    allocs: [NUM_THREADS]Allocator,
    num_runs: usize,
    buf_size: usize,
    num_bufs: usize,
    use_arena: bool,
};

fn runBench(bench: *const Bench) !void {
    if (bench.num_runs == 0) {
        std.debug.print("Skipping {s}\n", .{bench.name});
        return;
    }

    std.debug.print("Running {s} with buf_size = {d}\n", .{ bench.name, bench.buf_size });

    var timings = ArrayList(u64).init(std.heap.page_allocator);
    defer timings.deinit();

    var timer = try Timer.start();
    for (0..bench.num_runs) |_| {
        doNotOptimizeAway(try doOneRun(bench));
        try timings.append(timer.lap());
    }

    sort.pdq(u64, timings.items, {}, sort.asc(u64));

    const best = timings.items[0] / 1000;
    const median = timings.items[timings.items.len / 2] / 1000;
    const worst = timings.items[timings.items.len - 1] / 1000;

    std.debug.print("Best-Median-Worst running times in microseconds were {d}-{d}-{d}\n", .{ best, median, worst });
}

fn doOneRun(bench: *const Bench) !u64 {
    var results: [NUM_THREADS]anyerror!u64 = .{0} ** NUM_THREADS;
    var threads: [NUM_THREADS]std.Thread = undefined;

    for (0..NUM_THREADS) |i| {
        const thread = try std.Thread.spawn(.{}, doOneRunWrap, .{ i, Ctx{ .bench = bench, .out = &results[i] } });
        threads[i] = thread;
    }

    for (threads) |t| {
        t.join();
    }

    var acc: u64 = 0;
    for (results) |r| {
        acc +%= try r;
    }

    return acc;
}

const Ctx = struct {
    bench: *const Bench,
    out: *anyerror!u64,
};

fn doOneRunWrap(thread_id: usize, ctx: Ctx) void {
    for (0..24) |_| {
        const out = doOneRunThread(thread_id, ctx.bench) catch |e| {
            ctx.out.* = e;
            return;
        };
        ctx.out.* = out;
    }
}

fn doOneRunThread(thread_id: usize, bench: *const Bench) !u64 {
    const base_allocator = bench.allocs[thread_id];
    var arena = std.heap.ArenaAllocator{
        .child_allocator = base_allocator,
        .state = .{},
    };
    defer arena.deinit();
    var bump = huge_alloc.BumpAlloc.init(.{
        .child_allocator = base_allocator,
    });
    defer bump.deinit();
    const alloc = if (bench.use_arena) arena.allocator() else bump.allocator();

    var original = try alloc.alloc([]u64, bench.num_bufs);

    var rng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = rng.random();

    for (0..bench.num_bufs) |i| {
        const buf = try alloc.alloc(u64, bench.buf_size);
        original[i] = buf;

        for (0..buf.len) |j| {
            buf[j] = rand.int(u64);
        }
    }

    var compressed = try alloc.alloc([]u8, bench.num_bufs);

    var scratch = try alloc.alloc(u8, zstd.ZSTD_compressBound(bench.buf_size * 8));

    for (0..bench.num_bufs) |i| {
        const c_len = zstd.ZSTD_compress(scratch.ptr, scratch.len, original[i].ptr, original[i].len * 8, 8);
        if (zstd.ZSTD_isError(c_len) != 0) {
            @panic("failed to compress");
        }

        const buf = try alloc.alloc(u8, c_len);

        @memcpy(buf, scratch[0..c_len]);

        compressed[i] = buf;
    }

    var decompressed = try alloc.alloc([]u64, bench.num_bufs);

    for (0..bench.num_bufs) |i| {
        const buf = try alloc.alloc(u64, bench.buf_size);

        decompressed[i] = buf;

        const src_buf = compressed[i];
        const res = zstd.ZSTD_decompress(buf.ptr, buf.len * 8, src_buf.ptr, src_buf.len);
        if (0 != zstd.ZSTD_isError(res)) {
            @panic("failed to decompress");
        }
    }

    var accum = try alloc.alloc(u64, bench.buf_size);

    for (accum) |*x| {
        x.* = 0;
    }

    for (0..bench.buf_size) |i| {
        for (decompressed) |buf| {
            accum[accum.len - i - 1] +%= buf[buf.len - i - 1];
        }
    }

    var acc = @as(u64, 0);

    for (accum) |x| {
        acc +%= x;
    }

    return acc;
}
