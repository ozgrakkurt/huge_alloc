const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));
const huge_alloc = @import("huge_alloc");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Timer = std.time.Timer;
const sort = std.sort;
const doNotOptimizeAway = std.mem.doNotOptimizeAway;

const NUM_THREADS = 8;

pub fn main() !void {
    var huge_allocators: [NUM_THREADS]huge_alloc.HugePageAlloc = undefined;
    var huge_alloc_allocs: [NUM_THREADS]Allocator = undefined;

    for (0..NUM_THREADS) |i| {
        huge_allocators[i] = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.thp_alloc_vtable);
        huge_alloc_allocs[i] = huge_allocators[i].make_allocator();
    }

    defer for (&huge_allocators) |*a| {
        a.deinit();
    };

    var huge_2mb_allocators: [NUM_THREADS]huge_alloc.HugePageAlloc = undefined;
    var huge_2mb_alloc_allocs: [NUM_THREADS]Allocator = undefined;

    for (0..NUM_THREADS) |i| {
        huge_2mb_allocators[i] = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.huge_page_2mb_alloc_vtable);
        huge_2mb_alloc_allocs[i] = huge_2mb_allocators[i].make_allocator();
    }

    defer for (&huge_2mb_allocators) |*a| {
        a.deinit();
    };

    var huge_1gb_allocators: [NUM_THREADS]huge_alloc.HugePageAlloc = undefined;
    var huge_1gb_alloc_allocs: [NUM_THREADS]Allocator = undefined;

    for (0..NUM_THREADS) |i| {
        huge_1gb_allocators[i] = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.huge_page_1gb_alloc_vtable);
        huge_1gb_alloc_allocs[i] = huge_1gb_allocators[i].make_allocator();
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

    const allocs = if (std.mem.eql(u8, alloc_name, "huge_alloc"))
        huge_alloc_allocs
    else if (std.mem.eql(u8, alloc_name, "page_alloc"))
        .{std.heap.page_allocator} ** NUM_THREADS
    else if (std.mem.eql(u8, alloc_name, "general_purpose_alloc"))
        .{gpa_alloc} ** NUM_THREADS
    else if (std.mem.eql(u8, alloc_name, "huge_2mb_alloc"))
        huge_2mb_alloc_allocs
    else if (std.mem.eql(u8, alloc_name, "huge_1gb_alloc"))
        huge_1gb_alloc_allocs
    else
        @panic("unknown alloc name");

    runBench(&Bench{
        .name = alloc_name,
        .allocs = allocs,
        .num_runs = num_runs,
        .buf_size = buf_size,
        .num_bufs = mem_use / buf_size / 8 / 3,
    }) catch {
        std.debug.print("Failed to run {s} with buf_size = {d}\n", .{ alloc_name, buf_size });
    };
}

const Bench = struct {
    name: []const u8,
    allocs: [NUM_THREADS]Allocator,
    num_runs: usize,
    buf_size: usize,
    num_bufs: usize,
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
        doNotOptimizeAway(doOneRun(bench));
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
    for (0..16) |_| {
        const out = doOneRunThread(thread_id, ctx.bench) catch |e| {
            ctx.out.* = e;
            return;
        };
        ctx.out.* = out;
    }
}

fn doOneRunThread(thread_id: usize, bench: *const Bench) !u64 {
    var arena = std.heap.ArenaAllocator.init(bench.allocs[thread_id]);
    defer arena.deinit();
    const alloc = arena.allocator();

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
    var compressed_len = try alloc.alloc(usize, bench.num_bufs);

    for (0..bench.num_bufs) |i| {
        const needed_size = zstd.ZSTD_compressBound(bench.buf_size * 8);

        const buf = try alloc.alloc(u8, needed_size);
        compressed[i] = buf;

        const c_len = zstd.ZSTD_compress(buf.ptr, buf.len, original[i].ptr, original[i].len * 8, 8);
        if (zstd.ZSTD_isError(c_len) != 0) {
            @panic("failed to compress");
        }

        compressed_len[i] = c_len;
    }

    var decompressed = try alloc.alloc([]u64, bench.num_bufs);

    for (0..bench.num_bufs) |i| {
        const buf = try alloc.alloc(u64, bench.buf_size);

        decompressed[i] = buf;

        const res = zstd.ZSTD_decompress(buf.ptr, buf.len * 8, compressed[i].ptr, compressed_len[i]);
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

    for (decompressed) |buf| {
        alloc.free(buf);
    }

    var acc = @as(u64, 0);

    for (accum) |x| {
        acc +%= x;
    }

    return acc;
}
