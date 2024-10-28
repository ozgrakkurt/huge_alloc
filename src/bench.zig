const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));
const huge_alloc = @import("huge_alloc");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Timer = std.time.Timer;
const sort = std.sort;
const doNotOptimizeAway = std.mem.doNotOptimizeAway;

pub fn main() void {
    var huge_allocator = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.thp_alloc_vtable);
    defer huge_allocator.deinit();
    const huge_alloc_alloc = huge_allocator.make_allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    var huge_allocator_2mb = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.huge_page_2mb_alloc_vtable);
    defer huge_allocator_2mb.deinit();
    const huge_2mb_alloc = huge_allocator_2mb.make_allocator();

    var huge_allocator_1gb = huge_alloc.HugePageAlloc.init(std.heap.page_allocator, huge_alloc.huge_page_1gb_alloc_vtable);
    defer huge_allocator_1gb.deinit();
    const huge_1gb_alloc = huge_allocator_1gb.make_allocator();

    const names = [_][]const u8{ "huge_alloc", "page_alloc", "general_purpose_alloc", "huge_2mb_alloc", "huge_1gb_alloc" };
    const allocators = [_]Allocator{ huge_alloc_alloc, std.heap.page_allocator, gpa_alloc, huge_2mb_alloc, huge_1gb_alloc };

    const num_runs = 50;
    const buf_sizes = [_]usize{ 128, 128 * 1024, 1024 * 1024, 4 * 1024 * 1024, 10 * 1024 * 1024, 12 * 1024 * 1024 };
    const mem_use = 2 * 1024 * 1024;

    for (buf_sizes) |buf_size| {
        for (names, allocators) |name, alloc| {
            runBench(&Bench{
                .name = name,
                .alloc = alloc,
                .num_runs = num_runs,
                .buf_size = buf_size,
                .num_bufs = mem_use / buf_size,
            }) catch {
                std.debug.print("Failed to run {s} with buf_size = {d}\n", .{ name, buf_size });
            };
        }
    }
}

const Bench = struct {
    name: []const u8,
    alloc: Allocator,
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

    var timings = ArrayList(u64).init(bench.alloc);
    defer timings.deinit();

    var timer = try Timer.start();
    for (0..bench.num_runs) |_| {
        doNotOptimizeAway(doOneRun(bench));
        try timings.append(timer.lap());
    }

    sort.pdq(u64, timings.items, {}, sort.asc(u64));

    std.debug.print("Median running time was {d}μs\n", .{timings.items[timings.items.len / 2] / 1000});
}

fn doOneRun(bench: *const Bench) !u64 {
    var original = try bench.alloc.alloc([]u64, bench.num_bufs);
    defer bench.alloc.free(original);

    var rng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = rng.random();

    for (0..bench.num_bufs) |i| {
        const buf = try bench.alloc.alloc(u64, bench.buf_size);
        original[i] = buf;

        for (0..buf.len) |j| {
            buf[j] = rand.int(u64);
        }
    }

    defer for (original) |buf| {
        bench.alloc.free(buf);
    };

    var compressed = try bench.alloc.alloc([]u8, bench.num_bufs);
    var compressed_len = try bench.alloc.alloc(usize, bench.num_bufs);
    defer bench.alloc.free(compressed);
    defer bench.alloc.free(compressed_len);

    for (0..bench.num_bufs) |i| {
        const needed_size = zstd.ZSTD_compressBound(bench.buf_size * 8);

        const buf = try bench.alloc.alloc(u8, needed_size);
        compressed[i] = buf;

        const c_len = zstd.ZSTD_compress(buf.ptr, buf.len, original[i].ptr, original[i].len * 8, 8);
        if (zstd.ZSTD_isError(c_len) != 0) {
            @panic("failed to compress");
        }

        compressed_len[i] = c_len;
    }

    defer for (compressed) |buf| {
        bench.alloc.free(buf);
    };

    var decompressed = try bench.alloc.alloc([]u64, bench.num_bufs);
    defer bench.alloc.free(decompressed);

    for (0..bench.num_bufs) |i| {
        const buf = try bench.alloc.alloc(u64, bench.buf_size);

        decompressed[i] = buf;

        const res = zstd.ZSTD_decompress(buf.ptr, buf.len * 8, compressed[i].ptr, compressed_len[i]);
        if (0 != zstd.ZSTD_isError(res)) {
            @panic("failed to decompress");
        }
    }

    defer for (decompressed) |buf| {
        bench.alloc.free(buf);
    };

    var accum = try bench.alloc.alloc(u64, bench.buf_size);
    defer bench.alloc.free(accum);

    for (accum) |*x| {
        x.* = 0;
    }

    for (decompressed) |buf| {
        for (0..bench.buf_size) |i| {
            accum[i] +%= buf[i];
        }
    }

    var acc = @as(u64, 0);

    for (accum) |x| {
        acc +%= x;
    }

    return acc;
}
