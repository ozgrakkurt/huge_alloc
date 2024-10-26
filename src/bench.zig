const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));

pub fn main() void {
    const version = zstd.ZSTD_versionString();
    std.debug.print("Hello, zstd version is {s}!\n", .{version});
}
