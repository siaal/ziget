const Allocator = @import("std").mem.Allocator;
const assert = @import("std").debug.assert;
const Dir = @import("std").fs.Dir;
const log = @import("std").log;
const Sha256 = @import("std").crypto.hash.sha2.Sha256;
const std = @import("std");
const builtin = @import("builtin");

const Digest = @import("Digest.zig");

const DISTRIBUTION_SITE = std.Uri.parse("https://ziglang.org/download/index.json") catch unreachable;
const DEFAULT_BASE_DIR = "~/.local/";
const DEFAULT_DISTRIBUTION = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

const SHASUM_LENGTH = Sha256.digest_length * 2;

const TEMP_HOME = switch (builtin.os.tag) {
    .macos, .linux => "/tmp",
    else => @panic("I don't recognise that os"),
};

const ENV = struct {
    const prefix = "ZIGET_";
    pub const ROOT_DIR = prefix ++ "ROOT_DIR";
    pub const DISTRIBUTION = prefix ++ "DISTRIBUTION";
};

var stdout_mutex: std.Thread.Mutex = .{};
var stdout = std.io.getStdOut().writer();

fn print(comptime fmt: []const u8, items: anytype) void {
    stdout_mutex.lock();
    defer stdout_mutex.unlock();
    stdout.print(fmt, items) catch {};
}

fn println(comptime fmt: []const u8, items: anytype) void {
    const fmt_nl = fmt ++ "\n";
    print(fmt_nl, items);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    println("fatal: " ++ fmt, args);
    std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();
    var arena_impl = std.heap.ArenaAllocator.init(alloc);
    defer arena_impl.deinit();

    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    const root_dir, const root_dirname = bin: {
        const cwd = std.fs.cwd();

        if (env.get(ENV.ROOT_DIR)) |path| {
            const dl_dir = cwd.makeOpenPath(path, .{}) catch |err|
                std.debug.panic(
                "fatal: specified download directory `{s}` could not be opened or created: {any}",
                .{ path, err },
            );
            log.info("download directory: {s}", .{path});
            break :bin .{ dl_dir, path };
        }
        log.info("no {s} specified, defaulting to '{s}'", .{ ENV.ROOT_DIR, DEFAULT_BASE_DIR });
        const home = env.get("HOME") orelse std.debug.panic("error: $HOME not set", .{});
        const dirname = try std.fs.path.join(
            alloc,
            &.{ home, ".local" },
        );
        const dir = cwd.makeOpenPath(dirname, .{}) catch |err|
            std.debug.panic(
            "fatal: could not access, nor create download directory at {s} - {any}",
            .{ DEFAULT_BASE_DIR, err },
        );
        break :bin .{ dir, dirname };
    };
    defer alloc.free(root_dirname);

    const distribution = env.get(ENV.DISTRIBUTION) orelse DEFAULT_DISTRIBUTION;

    var tmp_home = try std.fs.openDirAbsolute(TEMP_HOME, .{});
    defer tmp_home.close();
    var build_dir, const build_dirname = try makeTmp(tmp_home);
    defer {
        build_dir.close();
        tmp_home.deleteTree(&build_dirname) catch |err| {
            log.err("failed to clean up tmp directory {s}{c}{s}: err: {any}", .{
                TEMP_HOME,
                std.fs.path.sep,
                &build_dirname,
                err,
            });
        };
    }

    try downloadZig(alloc, &arena_impl, build_dir, root_dir, distribution);
    try downloadZls(alloc, build_dir, root_dirname);
    println("Complete!", .{});
    std.process.cleanExit();
}

fn cleanupExistingZigInstallation(root_dir: Dir) !void {
    log.debug("cleaning up existing installation if exists", .{});
    _ = root_dir.deleteTree("lib/zig") catch |err| switch (err) {
        error.NotDir, error.BadPathName => {},
        else => return err,
    };
    _ = root_dir.deleteFile("bin/zig") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn downloadZig(alloc: Allocator, arena_impl: *std.heap.ArenaAllocator, build_dir: Dir, root_dir: Dir, distribution_name: []const u8) !void {
    const arena = arena_impl.allocator();

    const distribution = dist: {
        inline for (std.meta.fields(Digest.Version), 0..) |field, i| {
            if (std.mem.eql(u8, field.name, distribution_name)) {
                log.info("DEBUG: distribution: {s}", .{distribution_name});
                break :dist i;
            }
        }
        fatal("could not find distribution {s} in digest", .{distribution_name});
    };

    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();

    var master: struct {
        version: []const u8,
        date: []const u8,
        source: Digest.Source,
    } = dl: {
        var header_buf: [4 * 1024 * 1024]u8 = undefined;
        var req = try client.open(.GET, DISTRIBUTION_SITE, .{ .server_header_buffer = &header_buf });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        const body_reader = req.reader();
        var json_reader = std.json.reader(alloc, body_reader);
        defer json_reader.deinit();
        defer _ = arena_impl.reset(.retain_capacity);

        const digest = try std.json.parseFromTokenSourceLeaky(Digest, arena, &json_reader, .{
            .ignore_unknown_fields = true,
        });

        const master_version = try alloc.dupe(u8, digest.master.version);
        const master_date = try alloc.dupe(u8, digest.master.date);
        inline for (@typeInfo(Digest.Version).@"struct".fields, 0..) |field, idx| {
            if (idx == distribution and field.type == Digest.Source) {
                const result: Digest.Source = @field(digest.master, field.name);
                var clone: Digest.Source = undefined;
                inline for (std.meta.fields(Digest.Source)) |f| {
                    const fname = f.name;
                    @field(clone, fname) = try alloc.dupe(u8, @field(result, fname));
                }
                break :dl .{
                    .version = master_version,
                    .date = master_date,
                    .source = clone,
                };
            }
        }

        // We checked to make sure it was in the digest earlier
        unreachable;
    };
    defer {
        master.source.deinit(alloc);
        alloc.free(master.date);
        alloc.free(master.version);
    }

    const source_uri = std.Uri.parse(master.source.tarball) catch |err|
        std.debug.panic("fatal: could not parse url: {s}, {any}", .{ master.source.tarball, err });

    assert(master.source.shasum.len == SHASUM_LENGTH);
    const tarball_name = name: {
        const last_slash = std.mem.lastIndexOfScalar(u8, master.source.tarball, '/');
        break :name master.source.tarball[last_slash.? + 1 ..];
    };

    log.info("downloading zig tarball: ", .{});
    try downloadFile(alloc, build_dir, tarball_name, source_uri, master.source.shasum[0..SHASUM_LENGTH]);
    log.info("{s}{c}{s} downloaded successfully", .{ TEMP_HOME, std.fs.path.sep, tarball_name });
    log.info("extracting zig tarball: ", .{});
    try extractTarball(alloc, build_dir, tarball_name);
    log.info("{s}{c}{s} extracted successfully: ", .{ TEMP_HOME, std.fs.path.sep, tarball_name });

    try cleanupExistingZigInstallation(root_dir);

    const zig_dir_name = tarball_name[0 .. tarball_name.len - ".tar.xz".len];
    log.info("DEBUG: zig_dir_name: {s}", .{zig_dir_name});
    {
        defer _ = arena_impl.reset(.retain_capacity);
        errdefer |err| log.err("error in copying from tmp dir to zig dest {}", .{err});
        var zig_dest = try root_dir.makeOpenPath("lib", .{ .no_follow = true });
        defer zig_dest.close();
        try copyDir(
            build_dir,
            zig_dir_name,
            zig_dest,
            "zig",
        );

        var zig_exe = try zig_dest.openFile(try std.fs.path.join(arena, &.{ "zig", "zig" }), .{});
        defer zig_exe.close();
        try zig_exe.chmod(0o755);

        const bin_dest = try std.fs.path.join(arena, &.{ "bin", "zig" });
        root_dir.symLink(
            try std.fs.path.join(arena, &.{ "..", "lib", "zig", "zig" }),
            bin_dest,
            .{ .is_directory = false },
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const stat = try zig_dest.statFile(bin_dest);
                if (stat.kind == .sym_link) {
                    // touch file
                    errdefer |err| log.err("error touching file - poorly implemented? {}", .{err});
                    var file = try zig_dest.openFile(bin_dest, .{});
                    file.close();
                } else {
                    log.err("cannot symlink zig binary, already exists", .{});
                    return error.PathAlreadyExists;
                }
            },
            else => |e| try fail(e),
        };
    }

    println("Zig downloaded successfully", .{});
}

fn fail(e: anyerror) !void {
    return e;
}

pub fn makeTmp(home: Dir) !struct { Dir, [22]u8 } {
    while (true) {
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        var file_name: [(std.fs.base64_encoder.calcSize(random_bytes.len))]u8 = undefined;

        _ = std.fs.base64_encoder.encode(&file_name, &random_bytes);

        const dir = home.makeOpenPath(&file_name, .{ .access_sub_paths = true, .iterate = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return .{ dir, file_name };
    }
}

pub fn downloadFile(alloc: Allocator, dir: std.fs.Dir, filename: []const u8, dlUrl: std.Uri, shasum: *const [SHASUM_LENGTH]u8) !void {
    var file = dir.createFile(filename, .{ .mode = 0o755 }) catch |err| switch (err) {
        error.IsDir,
        error.FileLocksNotSupported,
        error.FileBusy,
        error.WouldBlock,
        error.NotDir,
        error.FileNotFound,
        error.BadPathName,
        error.PathAlreadyExists,
        => unreachable,

        else => |e| {
            log.err("could not create file {s} got error {}", .{ filename, e });
            return e;
        },
    };
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var headers: [4 * 1024 * 1024]u8 = undefined;
    var req = try client.open(.GET, dlUrl, .{ .server_header_buffer = &headers });
    defer req.deinit();

    {
        errdefer |err| log.err("error in sending request: {}", .{err});
        try req.send();
        try req.finish();
        try req.wait();
    }

    var sha = Sha256.init(.{});

    var writer = file.writer();
    var reader = req.reader();

    {
        var buf: [4096]u8 = undefined;
        var n: usize = 1;
        while (n > 0) {
            n = try reader.read(&buf);
            try writer.writeAll(buf[0..n]);
            sha.update(buf[0..n]);
        }
    }

    const final_sha = std.fmt.bytesToHex(sha.finalResult(), .lower);
    if (!std.ascii.eqlIgnoreCase(&final_sha, shasum)) {
        log.err("sha mismatch. file download failed: ", .{});
        dir.deleteFile(filename) catch {
            log.warn("could not clean up {s}: ", .{filename});
        };
        return error.Failed;
    }
}

pub fn extractTarball(alloc: Allocator, dir: Dir, tarName: []const u8) !void {
    errdefer |err| log.err("error in extractTarball tarname:{s} : {}", .{ tarName, err });
    var tarball = try dir.openFile(tarName, .{});
    const tar_reader = tarball.reader();

    var xz = try std.compress.xz.decompress(alloc, tar_reader);
    defer xz.deinit();

    try std.tar.pipeToFileSystem(dir, xz.reader(), .{ .mode_mode = .executable_bit_only });
}

test {
    std.testing.refAllDecls(@This());
}

fn copyDir(parent_dir: Dir, target: []const u8, to_dir: Dir, target_name: []const u8) !void {
    var from_dir = try parent_dir.openDir(target, .{ .iterate = true, .access_sub_paths = true, .no_follow = true });
    defer from_dir.close();
    var to_dir_sub = try to_dir.makeOpenPath(target_name, .{ .iterate = false, .access_sub_paths = true, .no_follow = true });
    defer to_dir_sub.close();

    try innerCopyDir(from_dir, to_dir_sub);
}

fn innerCopyDir(from_dir: Dir, to_dir: Dir) !void {
    var iter = from_dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                var to_sub_dir = try to_dir.makeOpenPath(entry.name, .{
                    .access_sub_paths = true,
                    .no_follow = true,
                });
                defer to_sub_dir.close();
                var from_sub_dir = try from_dir.openDir(entry.name, .{
                    .iterate = true,
                    .access_sub_paths = true,
                    .no_follow = true,
                });
                defer from_sub_dir.close();

                try innerCopyDir(from_sub_dir, to_sub_dir);
            },
            else => {
                try from_dir.copyFile(
                    entry.name,
                    to_dir,
                    entry.name,
                    .{},
                );
            },
        }
    }
}

fn downloadZls(alloc: Allocator, build_dir: Dir, root_dir_str: []const u8) !void {
    {
        errdefer |err| log.err("fatal error in downloadZLS: {}", .{err});
        println("cloning zls", .{});
        var git_proc = std.process.Child.init(
            &.{ "git", "clone", "https://github.com/zigtools/zls" },
            alloc,
        );
        git_proc.cwd_dir = build_dir;
        const term = try git_proc.spawnAndWait();
        switch (term) {
            .Exited => {},
            else => {
                log.err("fatal:git clone exited under illegal error condition {}", .{term});
                try fail(error.DownloadFailed);
            },
        }
        println("clone complete", .{});
    }

    {
        errdefer |err| log.err("fatal error in downloadZLS: {}", .{err});
        var zls_dir = try build_dir.openDir("zls", .{});
        defer zls_dir.close();
        println("building zls", .{});
        var build_proc = std.process.Child.init(
            &.{ "zig", "build", "-Doptimize=ReleaseSafe", "-p", root_dir_str },
            alloc,
        );
        build_proc.cwd_dir = zls_dir;
        const term = try build_proc.spawnAndWait();
        switch (term) {
            .Exited => {},
            else => {
                log.err("fatal:zig build exited under illegal error condition {}", .{term});
                try fail(error.DownloadFailed);
            },
        }
        println("zls built and installed", .{});
    }
    println("ZLS downloaded and installed successfully", .{});
}
