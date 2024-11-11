const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;

const ONE_GB = 1 * 1024 * 1024 * 1024;
const TWO_MB = 2 * 1024 * 1024;

const MIN_ALLOC_SIZE = 16 * TWO_MB;

pub const PageAllocVTable = struct {
    alloc_page: *const fn (size: usize) ?[]align(std.mem.page_size) u8,
    free_page: *const fn (page: []align(std.mem.page_size) u8) void,
};

pub const thp_alloc_vtable = PageAllocVTable{
    .alloc_page = alloc_thp,
    .free_page = posix.munmap,
};

fn alloc_thp(size: usize) ?[]align(std.mem.page_size) u8 {
    if (size == 0) {
        return null;
    }
    const aligned_size = align_up(size, TWO_MB);
    const alloc_size = @max(aligned_size, MIN_ALLOC_SIZE);
    const page = mmap_wrapper(alloc_size, 0) orelse return null;
    const ptr_alignment_offset = align_offset(@intFromPtr(page.ptr), TWO_MB);
    const thp_section = page[ptr_alignment_offset..];
    posix.madvise(@alignCast(thp_section.ptr), thp_section.len, posix.MADV.HUGEPAGE) catch {
        posix.munmap(page);
        return null;
    };
    return page;
}

pub const huge_page_1gb_alloc_vtable = PageAllocVTable{
    .alloc_page = alloc_huge_page_1gb,
    .free_page = posix.munmap,
};

pub const huge_page_2mb_alloc_vtable = PageAllocVTable{
    .alloc_page = alloc_huge_page_2mb,
    .free_page = posix.munmap,
};

fn alloc_huge_page_1gb(size: usize) ?[]align(std.mem.page_size) u8 {
    if (size == 0) {
        return null;
    }
    const aligned_size = align_up(size, ONE_GB);
    const page = mmap_wrapper(aligned_size, linux.HUGETLB_FLAG_ENCODE_1GB) orelse return null;
    return page;
}

fn alloc_test_page(size: usize) ?[]align(std.mem.page_size) u8 {
    if (size == 0) {
        return null;
    }
    const aligned_size = align_up(size, std.mem.page_size);
    const page = std.testing.allocator.alignedAlloc(
        u8,
        std.mem.page_size,
        aligned_size,
    ) catch return null;
    return @alignCast(page);
}

fn free_test_page(page: []align(std.mem.page_size) u8) void {
    std.testing.allocator.free(
        page,
    );
}

pub const test_page_alloc_vtable = PageAllocVTable{
    .alloc_page = alloc_test_page,
    .free_page = free_test_page,
};

fn alloc_huge_page_2mb(size: usize) ?[]align(std.mem.page_size) u8 {
    if (size == 0) {
        return null;
    }
    const aligned_size = align_up(size, TWO_MB);
    const alloc_size = @max(aligned_size, MIN_ALLOC_SIZE);
    const page = mmap_wrapper(alloc_size, linux.HUGETLB_FLAG_ENCODE_2MB) orelse return null;
    return page;
}

fn mmap_wrapper(size: usize, huge_page_flag: u32) ?[]align(std.mem.page_size) u8 {
    if (size == 0) {
        return null;
    }
    const flags = linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = huge_page_flag != 0, .POPULATE = true, .LOCKED = true };
    const flags_int: u32 = @bitCast(flags);
    const flags_f: linux.MAP = @bitCast(flags_int | huge_page_flag);
    const page = posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, flags_f, -1, 0) catch return null;
    return page;
}

pub const Config = struct {
    free_after: usize = std.math.maxInt(usize),
    base_alloc: Allocator = std.heap.page_allocator,
    page_alloc_vtable: PageAllocVTable = thp_alloc_vtable,
};

pub const HugePageAlloc = struct {
    pages: ArrayList([]align(std.mem.page_size) u8),
    free_list: ArrayList(ArrayList([]u8)),
    page_alloc: PageAllocVTable,
    base_alloc: Allocator,
    free_after: usize,
    total_size: usize,

    pub fn init(cfg: Config) HugePageAlloc {
        return HugePageAlloc{
            .pages = ArrayList([]align(std.mem.page_size) u8).init(cfg.base_alloc),
            .free_list = ArrayList(ArrayList([]u8)).init(cfg.base_alloc),
            .page_alloc = cfg.page_alloc_vtable,
            .base_alloc = cfg.base_alloc,
            .free_after = cfg.free_after,
            .total_size = 0,
        };
    }

    pub fn deinit(self: *HugePageAlloc) void {
        for (self.free_list.items) |free_l| {
            free_l.deinit();
        }
        self.free_list.deinit();
        for (self.pages.items) |page| {
            self.page_alloc.free_page(page);
        }
        self.pages.deinit();
    }

    fn try_alloc_in_existing_pages(self: *HugePageAlloc, size: usize, align_to: usize) ?[*]u8 {
        for (self.free_list.items) |*free_ranges| {
            for (0..free_ranges.items.len) |free_range_idx| {
                const free_range = free_ranges.*.items[free_range_idx];
                const pos = @intFromPtr(free_range.ptr);
                const alignment_offset = align_offset(pos, align_to);
                if (free_range.len >= alignment_offset + size) {
                    var appended = false;
                    if (alignment_offset > 0) {
                        free_ranges.append(free_range.ptr[0..alignment_offset]) catch return null;
                        appended = true;
                    }

                    if (alignment_offset + size < free_range.len) {
                        free_ranges.append(free_range.ptr[alignment_offset + size .. free_range.len]) catch {
                            if (appended) {
                                _ = free_ranges.pop();
                            }
                            return null;
                        };
                    }

                    _ = free_ranges.swapRemove(free_range_idx);

                    return @ptrCast(&free_range.ptr[alignment_offset]);
                }
            }
        }

        return null;
    }

    fn alloc_on_new_page(self: *HugePageAlloc, page: []align(std.mem.page_size) u8, size: usize) ![*]u8 {
        try self.pages.append(page);
        errdefer _ = self.pages.pop();

        var free_ranges = ArrayList([]u8).init(self.base_alloc);
        errdefer free_ranges.deinit();

        try free_ranges.append(page[size..]);
        try self.free_list.append(free_ranges);

        return @ptrCast(page.ptr);
    }

    fn alloc(ctx: *anyopaque, size: usize, log2_ptr_align: u8, return_address: usize) ?[*]u8 {
        _ = return_address;
        const self: *HugePageAlloc = @ptrCast(@alignCast(ctx));

        if (size == 0) {
            return null;
        }
        const align_to: usize = usize_from_log2(log2_ptr_align);
        if (align_to > std.mem.page_size) {
            return null;
        }
        const existing_page_ptr = self.try_alloc_in_existing_pages(size, align_to);
        if (existing_page_ptr) |ptr| {
            return ptr;
        }

        const page = self.page_alloc.alloc_page(size) orelse return null;
        self.total_size += page.len;
        const ptr = self.alloc_on_new_page(page, size) catch {
            self.page_alloc.free_page(page);
            return null;
        };
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, return_address: usize) bool {
        if (new_len == 0) {
            return false;
        }

        if (buf.len > new_len) {
            HugePageAlloc.free(ctx, buf[new_len..], log2_buf_align, return_address);
            return true;
        }

        const self: *HugePageAlloc = @ptrCast(@alignCast(ctx));

        const end_addr: usize = @intFromPtr(buf.ptr) + buf.len;

        if (buf.len == new_len) {
            return false;
        }

        for (self.free_list.items) |*free_ranges| {
            for (0..free_ranges.items.len) |free_range_idx| {
                const free_range = free_ranges.items[free_range_idx];
                const free_range_start_addr = @intFromPtr(free_range.ptr);
                if (free_range_start_addr == end_addr) {
                    if (free_range.len + buf.len > new_len) {
                        const offset = new_len - buf.len;
                        free_ranges.items[free_range_idx] = free_range[offset..];
                        return true;
                    } else if (free_range.len + buf.len == new_len) {
                        _ = free_ranges.swapRemove(free_range_idx);
                        return true;
                    } else {
                        return false;
                    }
                }
            }
        }

        return false;
    }

    pub fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, return_address: usize) void {
        _ = log2_buf_align;
        _ = return_address;

        const self: *HugePageAlloc = @ptrCast(@alignCast(ctx));

        const start_addr: usize = @intFromPtr(buf.ptr);
        const end_addr: usize = start_addr + buf.len;

        for (0..self.free_list.items.len) |page_idx| {
            const free_ranges = &self.free_list.items[page_idx];
            var range_to_insert = buf;
            var free_range_idx = @as(usize, 0);
            var found = false;

            {
                const page = self.pages.items[page_idx];
                const page_addr = @intFromPtr(page.ptr);
                const buf_addr = @intFromPtr(buf.ptr);
                const contains = buf_addr >= page_addr and page_addr + page.len >= buf_addr + buf.len;
                if (!contains) {
                    continue;
                }
            }

            while (free_range_idx < free_ranges.items.len) {
                const free_range = free_ranges.items[free_range_idx];
                const free_range_start_addr = @intFromPtr(free_range.ptr);
                const free_range_end_addr = free_range_start_addr + free_range.len;
                if (free_range_start_addr == end_addr) {
                    range_to_insert = range_to_insert.ptr[0 .. range_to_insert.len + free_range.len];
                    _ = free_ranges.swapRemove(free_range_idx);
                    if (found) {
                        break;
                    }
                    found = true;
                } else if (free_range_end_addr == start_addr) {
                    range_to_insert = free_range.ptr[0 .. range_to_insert.len + free_range.len];
                    _ = free_ranges.swapRemove(free_range_idx);
                    if (found) {
                        break;
                    }
                    found = true;
                } else {
                    free_range_idx += 1;
                }
            }
            if (found) {
                free_ranges.append(range_to_insert) catch unreachable;
            } else {
                free_ranges.append(buf) catch @panic("unrecoverable failure");
            }
            if (self.should_free()) {
                var page_index: usize = 0;
                while (page_index < self.pages.items.len) {
                    const free_r = self.free_list.items[page_index];
                    if (free_r.items.len == 1) {
                        const range = free_ranges.items[0];
                        const page = self.pages.items[page_index];
                        if (range.ptr == page.ptr and range.len == page.len) {
                            self.page_alloc.free_page(page);
                            self.total_size -= page.len;
                            _ = self.pages.swapRemove(page_index);
                            const free_l = self.free_list.swapRemove(page_index);
                            free_l.deinit();
                            continue;
                        }
                    }
                    page_index += 1;
                }
            }
            return;
        }

        @panic("bad free, page not found");
    }

    fn should_free(self: *HugePageAlloc) bool {
        return self.total_size > self.free_after;
    }

    pub fn allocator(self: *HugePageAlloc) Allocator {
        return Allocator{
            .vtable = &huge_alloc_vtable,
            .ptr = self,
        };
    }
};

const huge_alloc_vtable = Allocator.VTable{
    .alloc = HugePageAlloc.alloc,
    .resize = HugePageAlloc.resize,
    .free = HugePageAlloc.free,
};

fn align_offset(pos: usize, align_to: usize) usize {
    return align_up(pos, align_to) - pos;
}

fn align_up(v: usize, align_v: usize) usize {
    return (v + align_v - 1) & ~(align_v - 1);
}

pub const BumpConfig = struct {
    child_allocator: Allocator,
    budget: usize = std.math.maxInt(usize),
};

pub const BumpAlloc = struct {
    child_allocator: Allocator,
    allocs: ArrayList([]u8),
    budget: usize,
    buf: []u8,

    pub fn init(cfg: BumpConfig) BumpAlloc {
        return .{
            .child_allocator = cfg.child_allocator,
            .allocs = ArrayList([]u8).init(cfg.child_allocator),
            .budget = cfg.budget,
            .buf = &.{},
        };
    }

    pub fn deinit(self: *BumpAlloc) void {
        for (self.allocs.items) |a| {
            self.child_allocator.free(a);
        }
        self.allocs.deinit();
    }

    fn alloc(ctx: *anyopaque, size: usize, log2_ptr_align: u8, return_address: usize) ?[*]u8 {
        _ = return_address;
        const self: *BumpAlloc = @ptrCast(@alignCast(ctx));
        if (size == 0) {
            return null;
        }
        const align_to: usize = usize_from_log2(log2_ptr_align);
        if (align_to > std.mem.page_size) {
            return null;
        }
        const pos = @intFromPtr(self.buf.ptr);
        const alignment_offset = align_offset(pos, align_to);

        if (self.buf.len >= alignment_offset + size) {
            const page = self.buf[alignment_offset .. alignment_offset + size];
            self.buf = self.buf[alignment_offset + size ..];
            return page.ptr;
        } else {
            const alloc_size = @max(MIN_ALLOC_SIZE / 8, size);

            if (alloc_size > self.budget) {
                return null;
            }

            const new_buf = self.child_allocator.alloc(u8, alloc_size) catch return null;
            self.buf = new_buf[size..];

            self.allocs.append(new_buf) catch {
                self.child_allocator.free(new_buf);
                return null;
            };

            self.budget -= alloc_size;

            return new_buf[0..size].ptr;
        }
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, return_address: usize) bool {
        _ = ctx;
        _ = buf;
        _ = log2_buf_align;
        _ = new_len;
        _ = return_address;

        return false;
    }

    pub fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, return_address: usize) void {
        _ = ctx;
        _ = buf;
        _ = log2_buf_align;
        _ = return_address;
    }

    pub fn allocator(self: *BumpAlloc) Allocator {
        return Allocator{
            .vtable = &bump_alloc_vtable,
            .ptr = self,
        };
    }
};

const bump_alloc_vtable = Allocator.VTable{
    .alloc = BumpAlloc.alloc,
    .resize = BumpAlloc.resize,
    .free = BumpAlloc.free,
};

fn usize_from_log2(log2align: u8) usize {
    return @as(usize, 1) << @as(Allocator.Log2Align, @intCast(log2align));
}

test "alloc_thp" {
    const page = alloc_thp(13) orelse @panic("failed alloc");
    defer posix.munmap(page);
    try std.testing.expect(page.len > 13);
    try std.testing.expect(page.len % std.mem.page_size == 0);
}

test "alloc_huge_page_1gb" {
    const page = alloc_huge_page_1gb(13) orelse return error.SkipZigTest;
    defer posix.munmap(page);
    try std.testing.expect(page.len >= 1 * 1024 * 1024 * 1024);
}

test "alloc_huge_page_2mb" {
    const page = alloc_huge_page_2mb(13) orelse return error.SkipZigTest;
    defer posix.munmap(page);
    try std.testing.expect(page.len >= 2 * 1024 * 1024);
}

test "alloc_test_page" {
    const page = alloc_test_page(13) orelse @panic("failed alloc");
    defer free_test_page(page);
    try std.testing.expect(page.len >= std.mem.page_size);
}

test "huge_page_alloc" {
    var huge_alloc = HugePageAlloc.init(.{ .base_alloc = std.testing.allocator, .page_alloc_vtable = test_page_alloc_vtable });
    defer huge_alloc.deinit();

    const ptr = HugePageAlloc.alloc(@ptrCast(&huge_alloc), 12, 4, 0) orelse @panic("failed alloc");
    const buf = ptr[0..12];
    defer HugePageAlloc.free(@ptrCast(&huge_alloc), buf, 4, 0);

    const ptr2 = HugePageAlloc.alloc(@ptrCast(&huge_alloc), 13, 8, 0) orelse @panic("failed alloc");
    const buf2 = ptr2[0..13];
    defer HugePageAlloc.free(@ptrCast(&huge_alloc), buf2, 8, 0);

    const ptr3 = HugePageAlloc.alloc(@ptrCast(&huge_alloc), 13, 8, 0) orelse @panic("failed alloc");
    const buf3 = ptr3[0..13];
    HugePageAlloc.free(@ptrCast(&huge_alloc), buf3, 8, 0);

    const alloc = huge_alloc.allocator();

    var list = ArrayList(u64).init(alloc);
    try list.append(12);
    try list.append(13);
    for (0..257) |i| {
        try list.append(i);
    }
    defer list.deinit();
}

test "align up" {
    const sizes = [_]usize{ TWO_MB, ONE_GB, std.mem.page_size };

    for (sizes) |size| {
        try std.testing.expectEqual(align_up(0, size), 0);
        try std.testing.expectEqual(align_up(13, size), size);
        try std.testing.expectEqual(align_up(size, size), size);
        try std.testing.expectEqual(align_up(size + 1, size), 2 * size);
    }
}

test "align_offset" {
    const align_to_values = [_]usize{ 2, 4, TWO_MB, ONE_GB, std.mem.page_size };
    const positions = [_]usize{ 0, 1, 3, 5, TWO_MB, ONE_GB, TWO_MB + 1, TWO_MB - 1, ONE_GB + 1, ONE_GB - 1, std.mem.page_size };

    for (align_to_values) |align_to| {
        for (positions) |pos| {
            const alignment_offset = align_offset(pos, align_to);
            try std.testing.expectEqual((alignment_offset + pos) % align_to, 0);
            try std.testing.expectEqual(align_offset(pos + alignment_offset, align_to), 0);
            try std.testing.expectEqual(align_up(pos, align_to), pos + alignment_offset);
            try std.testing.expect(alignment_offset < align_to);
        }
    }
}

test "test allocator with std" {
    var huge_alloc = HugePageAlloc.init(.{ .base_alloc = std.testing.allocator, .page_alloc_vtable = test_page_alloc_vtable });
    defer huge_alloc.deinit();
    const alloc = huge_alloc.allocator();

    try std.heap.testAllocator(alloc);
    try std.heap.testAllocatorAligned(alloc);
    try std.heap.testAllocatorLargeAlignment(alloc);
    try std.heap.testAllocatorAlignedShrink(alloc);

    var bump = BumpAlloc.init(.{ .child_allocator = alloc });
    defer bump.deinit();
    const bump_alloc = bump.allocator();

    try std.heap.testAllocator(bump_alloc);
    try std.heap.testAllocatorAligned(bump_alloc);
    try std.heap.testAllocatorLargeAlignment(bump_alloc);
    try std.heap.testAllocatorAlignedShrink(bump_alloc);
}

fn to_fuzz(input: []const u8) anyerror!void {
    if (input.len < 4) {
        return;
    }

    var huge_alloc = HugePageAlloc.init(.{ .base_alloc = std.testing.allocator, .page_alloc_vtable = test_page_alloc_vtable });
    defer huge_alloc.deinit();
    const alloc = huge_alloc.allocator();

    {
        var arrays = ArrayList([]u8).init(alloc);
        defer arrays.deinit();
        defer for (arrays.items) |arr| {
            alloc.free(arr);
        };

        for (0..input.len - 4) |i| {
            const len = @min(TWO_MB * 8, std.mem.readInt(usize, @ptrCast(input[i .. i + 4]), .big));

            try arrays.append(try alloc.alloc(u8, len));
        }

        for (4..input.len) |i| {
            const idx = input.len - i - 1;

            const len = @min(TWO_MB, std.mem.readInt(usize, @ptrCast(input[idx .. idx + 4]), .big));

            const arr: *[]u8 = &arrays.items[idx];

            if (alloc.resize(arr.*, len)) {
                arr.* = arr.*[0..len];
            }

            alloc.free(arr.*);
            arr.* = try alloc.alloc(u8, len);
        }

        for (arrays.items, 0..) |a, a_i| {
            for (arrays.items, 0..) |b, b_i| {
                if (a_i == b_i) {
                    continue;
                }
                try std.testing.expect(!overlaps(a, b));
            }
        }
    }
}

fn overlaps(a: []u8, b: []u8) bool {
    const a_start_addr = @intFromPtr(a.ptr);
    const a_end_addr = a_start_addr + a.len;
    const b_start_addr = @intFromPtr(b.ptr);
    const b_end_addr = b_start_addr + b.len;

    return (a_start_addr >= b_start_addr and a_start_addr < b_end_addr) or (b_start_addr >= a_start_addr and b_start_addr < a_end_addr);
}

test "fuzz alloc" {
    try std.testing.fuzz(to_fuzz, .{});
}
