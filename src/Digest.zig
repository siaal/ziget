const Allocator = @import("std").mem.Allocator;

master: Version,

pub const Version = struct {
    version: []const u8,
    date: []const u8,
    docs: []const u8,
    stdDocs: []const u8,
    src: Source,
    bootstrap: Source,
    @"x86_64-macos": Source,
    @"aarch64-macos": Source,
    @"x86_64-linux": Source,
    @"aarch64-linux": Source,
    @"armv7a-linux": Source,
    @"riscv64-linux": Source,
    @"powerpc64le-linux": Source,
    @"x86-linux": Source,
    @"loongarch64-linux": Source,
    @"x86_64-windows": Source,
    @"aarch64-windows": Source,
    @"x86-windows": Source,
};

pub const Source = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: []const u8,

    pub fn deinit(self: *Source, alloc: Allocator) void {
        alloc.free(self.tarball);
        alloc.free(self.shasum);
        alloc.free(self.size);
        self.* = undefined;
    }
};
