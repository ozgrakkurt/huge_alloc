const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));
const huge_alloc = @import("huge_alloc");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Timer = std.time.Timer;
const sort = std.sort;
const doNotOptimizeAway = std.mem.doNotOptimizeAway;

const NUM_THREADS = 12;

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
    const mem_use_str = args.next() orelse @panic("mem_size argument not found");
    const mem_use = try std.fmt.parseInt(usize, mem_use_str, 10);

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
        .use_arena = use_arena,
        .mem_use = mem_use,
    }) catch {
        std.debug.print("Failed to run {s}\n", .{alloc_name});
    };
}

//fn next_power_of_two(comptime T: type, val: T) T {
//    return std.math.shl(T, 1, (@typeInfo(T).int.bits - @clz(val -% @as(T, 1))));
//}

const Bench = struct {
    name: []const u8,
    allocs: [NUM_THREADS]Allocator,
    use_arena: bool,
    mem_use: usize,
};

fn runBench(bench: *const Bench) !void {
    var timer = try Timer.start();

    doNotOptimizeAway(try doOneRun(bench));

    const timing = timer.lap();

    std.debug.print("Running time was {d}μs\n", .{timing / 1000});
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
    for (0..32) |_| {
        const out = doOneRunThread(thread_id, ctx.bench) catch |e| {
            ctx.out.* = e;
            return;
        };
        ctx.out.* = out;
    }
}

fn doOneRunThread(thread_id: usize, bench: *const Bench) !u64 {
    const mem_use = bench.mem_use / NUM_THREADS;
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

    var rng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = rng.random();

    const BUF_LEN_FACTOR = 3;
    var buf_lengths = ArrayList(usize).init(alloc);
    var total_buf_len: usize = 0;
    const buf_len_limit = mem_use / BUF_LEN_FACTOR / 8;
    const MAX_BUF_LEN = 1 << 20;
    const MIN_BUF_LEN = 128;
    while (true) {
        const len = rand.floatNorm(f64) * 5.0 + 300000.0;
        const buf_len: usize = @intFromFloat(len);
        if (buf_len >= MIN_BUF_LEN and buf_len <= MAX_BUF_LEN) {
            total_buf_len +|= buf_len;
            if (total_buf_len > buf_len_limit) {
                break;
            }
            try buf_lengths.append(buf_len);
        }
    }
    const num_bufs = buf_lengths.items.len;

    var original = try alloc.alloc([]u64, num_bufs);

    for (buf_lengths.items, 0..) |buf_len, i| {
        const buf = try alloc.alloc(u64, buf_len);
        original[i] = buf;
        for (0..buf.len) |j| {
            buf[j] = rand.int(u64);
        }
    }

    var compressed = try alloc.alloc([]u8, num_bufs);

    var scratch = try alloc.alloc(u8, zstd.ZSTD_compressBound(MAX_BUF_LEN * 8));

    for (0..num_bufs) |i| {
        const c_len = zstd.ZSTD_compress(scratch.ptr, scratch.len, original[i].ptr, original[i].len * 8, 3);
        if (zstd.ZSTD_isError(c_len) != 0) {
            @panic("failed to compress");
        }

        const buf = try alloc.alloc(u8, c_len);

        @memcpy(buf, scratch[0..c_len]);

        compressed[i] = buf;
    }

    var decompressed = try alloc.alloc([]u64, num_bufs);

    for (buf_lengths.items, 0..) |buf_len, i| {
        const buf = try alloc.alloc(u64, buf_len);

        decompressed[i] = buf;

        const src_buf = compressed[i];
        const res = zstd.ZSTD_decompress(buf.ptr, buf.len * 8, src_buf.ptr, src_buf.len);
        if (0 != zstd.ZSTD_isError(res)) {
            @panic("failed to decompress");
        }
    }

    var accum = try alloc.alloc(u64, MAX_BUF_LEN);

    @memset(accum, 0);

    for (decompressed) |buf| {
        for (0..buf.len) |i| {
            accum[accum.len - i - 1] +%= buf[buf.len - i - 1];
        }
    }

    var acc = @as(u64, 0);

    for (accum) |x| {
        acc +%= x;
    }

    return acc;
}
