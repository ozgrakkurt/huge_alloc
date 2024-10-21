const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const c = std.c;
const linux = std.os.linux;

const ONE_GB = 1 * 1024 * 1024 * 1024;
const TWO_MB = 2 * 1024 * 1024;

pub const PageAllocVTable = struct {
    alloc_page: *const fn (size: usize) ?[]align(TWO_MB) u8,
    free_page: *const fn (page: []align(TWO_MB) u8) void,
};

pub const thp_alloc_vtable = PageAllocVTable{
    .alloc_page = alloc_thp,
    .free_page = free_thp,
};

fn alloc_thp(size: usize) ?[]align(TWO_MB) u8 {
    if (size == 0) {
        return null;
    }
    const aligned_size = align_up(size, TWO_MB);
    var ptr: ?*anyopaque = undefined;
    if (c.posix_memalign(&ptr, TWO_MB, aligned_size) != 0) {
        return null;
    }
    const data_ptr = @as([*]u8, @ptrCast(ptr));
    const aligned_data_ptr: [*]align(TWO_MB) u8 = @alignCast(data_ptr);
    posix.madvise(aligned_data_ptr, aligned_size, posix.MADV.HUGEPAGE) catch {
        c.free(data_ptr);
        return null;
    };
    return aligned_data_ptr[0..aligned_size];
}

fn free_thp(page: []align(TWO_MB) u8) void {
    c.free(page.ptr);
}

pub const huge_page_1gb_alloc_vtable = PageAllocVTable{
    .alloc_page = alloc_huge_page_1gb,
    .free_page = linux.munmap,
};

pub const huge_page_2mb_alloc_vtable = PageAllocVTable{
    .alloc_page = alloc_huge_page_2mb,
    .free_page = linux.munmap,
};

fn alloc_huge_page_1gb(size: usize) ?[]align(TWO_MB) u8 {
    if (size == 0) {
        return null;
    }
    const aligned_size = align_up(size, ONE_GB);
    const page = mmap_wrapper(aligned_size, linux.HUGETLB_FLAG_ENCODE_1GB) orelse return null;
    return page;
}

fn alloc_huge_page_2mb(size: usize) ?[]align(TWO_MB) u8 {
    if (size == 0) {
        return null;
    }
    const aligned_size = align_up(size, TWO_MB);
    const page = mmap_wrapper(aligned_size, linux.HUGETLB_FLAG_ENCODE_2MB) orelse return null;
    return page;
}

fn mmap_wrapper(size: usize, huge_page_flag: u32) ?[]align(TWO_MB) u8 {
    if (size == 0) {
        return null;
    }
    const flags = linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = true };
    const flags_int: u32 = @bitCast(flags);
    const flags_f: linux.MAP = @bitCast(flags_int | huge_page_flag);
    const page = posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, flags_f, -1, 0) catch return null;
    return @alignCast(page);
}

fn align_up(v: usize, align_v: usize) usize {
    return (v + align_v - 1) & ~(align_v - 1);
}

pub const HugePageAlloc = struct {
    pages: ArrayList([]align(TWO_MB) u8),
    free_list: ArrayList(ArrayList([]align(TWO_MB) u8)),
    page_alloc: PageAllocVTable,

    pub fn init(base_alloc: Allocator, v_table: PageAllocVTable) HugePageAlloc {
        return HugePageAlloc{
            .pages = ArrayList([]align(TWO_MB) u8).init(base_alloc),
            .free_list = ArrayList(ArrayList([]align(TWO_MB) u8)).init(base_alloc),
            .page_alloc = v_table,
        };
    }

    pub fn deinit(self: *HugePageAlloc) void {
        for (self.free_list.items) |free_l| {
            free_l.deinit();
        }
        self.free_list.deinit();
        self.pages.deinit();
    }

    pub fn alloc(_: *anyopaque, n: usize, log2_ptr_align: u8, return_address: usize) ?[*]u8 {
        _ = return_address;
        //_: *HugePageAlloc = @ptrCast(@alignCast(ctx));
        if (n == 0) {
            return null;
        }
        const align_to: usize = 1 << log2_ptr_align;
        if (align_to > TWO_MB) {
            return null;
        }
    }
};

test "smoke_alloc_thp" {
    const page = alloc_thp(13) orelse @panic("failed alloc");
    defer free_thp(page);
    try std.testing.expect(page.len == 2 * 1024 * 1024);
}

test "smoke_alloc_huge_page_1gb" {
    const page = alloc_huge_page_1gb(13) orelse return error.SkipZigTest;
    defer posix.munmap(page);
    try std.testing.expect(page.len == 1 * 1024 * 1024 * 1024);
}

test "smoke_alloc_huge_page_2mb" {
    const page = alloc_huge_page_2mb(13) orelse return error.SkipZigTest;
    defer posix.munmap(page);
    try std.testing.expect(page.len == 2 * 1024 * 1024);
}

test "smoke_huge_page_alloc" {
    var huge_alloc = HugePageAlloc.init(std.testing.allocator, thp_alloc_vtable);
    defer huge_alloc.deinit();
}

test "align up" {
    try std.testing.expectEqual(align_up(0, TWO_MB), 0);
    try std.testing.expectEqual(align_up(13, TWO_MB), TWO_MB);
    try std.testing.expectEqual(align_up(TWO_MB, TWO_MB), TWO_MB);
    try std.testing.expectEqual(align_up(TWO_MB + 1, TWO_MB), 2 * TWO_MB);
    try std.testing.expectEqual(align_up(0, ONE_GB), 0);
    try std.testing.expectEqual(align_up(13, ONE_GB), ONE_GB);
    try std.testing.expectEqual(align_up(ONE_GB, ONE_GB), ONE_GB);
    try std.testing.expectEqual(align_up(ONE_GB + 1, ONE_GB), 2 * ONE_GB);
}
