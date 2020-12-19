const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const tmpDir = std.testing.tmpDir;

const Allocator = mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
const OsTag = std.Target.Os.Tag;

const Arch = enum {
    any,
    aarch64,
    x86_64,

    fn fromTargetCpuArch(comptime arch: std.Target.Cpu.Arch) Arch {
        return switch (arch) {
            .aarch64 => .aarch64,
            .x86_64 => .x86_64,
            else => @compileError("unsupported CPU architecture"),
        };
    }
};

const Abi = enum {
    any,
    gnu,
};

const Target = struct {
    arch: Arch,
    os: OsTag = .macos,
    abi: Abi = .gnu,

    fn hash(a: Target) u32 {
        return @enumToInt(a.arch) +%
            (@enumToInt(a.os) *% @as(u32, 4202347608)) +%
            (@enumToInt(a.abi) *% @as(u32, 4082223418));
    }

    fn eql(a: Target, b: Target) bool {
        return a.arch == b.arch and a.os == b.os and a.abi == b.abi;
    }

    fn name(self: Target, allocator: *Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{}-{}-{}", .{
            @tagName(self.arch),
            @tagName(self.os),
            @tagName(self.abi),
        });
    }
};

const targets = [_]Target{
    Target{
        .arch = .any,
        .abi = .any,
    },
    Target{
        .arch = .aarch64,
    },
    Target{
        .arch = .x86_64,
    },
};

const dest_target: Target = .{
    .arch = Arch.fromTargetCpuArch(builtin.arch),
};

const headers_source_prefix: []const u8 = "libc/include";
const common_name = "any-macos-any";

const Contents = struct {
    bytes: []const u8,
    hit_count: usize,
    hash: []const u8,
    is_generic: bool,

    fn hitCountLessThan(context: void, lhs: *const Contents, rhs: *const Contents) bool {
        return lhs.hit_count < rhs.hit_count;
    }
};

const HashToContents = std.StringHashMap(Contents);
const TargetToHash = std.ArrayHashMap(Target, []const u8, Target.hash, Target.eql, true);
const PathTable = std.StringHashMap(*TargetToHash);

const usage =
    \\Usage: fetch_them_macos_headers [cflags]
    \\       fetch_them_macos_headers install [destination]
    \\
    \\Commands:
    \\  <empty> [cflags] (default)  Fetch macOS libc headers into <arch>-macos-gnu local directory
    \\  install [destination]       Install <arch>-macos-gnu header directory into a given destination path
    \\
    \\General Options:
    \\-h, --help                    Print this help and exit
;

fn mainArgs(allocator: *Allocator, all_args: []const []const u8) !void {
    const args = all_args[1..];
    if (args.len > 0) {
        const first_arg = args[0];
        if (mem.eql(u8, first_arg, "--help") or mem.eql(u8, first_arg, "-h")) {
            try io.getStdOut().writeAll(usage);
            return;
        } else if (mem.eql(u8, first_arg, "install")) {
            return installHeaders(allocator, args[1..]);
        } else {
            return fetchHeaders(allocator, args[1..]);
        }
    } else {
        return fetchHeaders(allocator, args);
    }
}

fn fetchHeaders(allocator: *Allocator, args: []const []const u8) !void {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    const tmp_filename = "headers";
    const tmp_file_path = try fs.path.join(allocator, &[_][]const u8{ tmp_path, tmp_filename });

    const headers_list_filename = "headers.o.d";
    const headers_list_path = try fs.path.join(allocator, &[_][]const u8{ tmp_path, headers_list_filename });

    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.appendSlice(&[_][]const u8{
        "cc",
        "-o",
        tmp_file_path,
        "src/headers.c",
        "-MD",
        "-MV",
        "-MF",
        headers_list_path,
    });
    try argv.appendSlice(args);

    // TODO instead of calling `cc` as a child process here,
    // hook in directly to `zig cc` API.
    const res = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv.items,
    });

    if (res.stderr.len != 0) {
        std.debug.print("{}\n", .{res.stderr});
    }

    // Read in the contents of `upgrade.o.d`
    const headers_list_file = try tmp.dir.openFile(headers_list_filename, .{});
    defer headers_list_file.close();

    var headers_dir = try fs.cwd().openDir(headers_source_prefix, .{});
    defer headers_dir.close();

    const dest_path = try dest_target.name(allocator);
    try headers_dir.deleteTree(dest_path);

    var dest_dir = try headers_dir.makeOpenPath(dest_path, .{});
    var dirs = std.StringHashMap(fs.Dir).init(allocator);
    try dirs.putNoClobber(".", dest_dir);

    const headers_list_str = try headers_list_file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    const prefix = "/usr/include";

    var it = mem.split(headers_list_str, "\n");
    while (it.next()) |line| {
        if (mem.lastIndexOf(u8, line, "clang") != null) continue;
        if (mem.lastIndexOf(u8, line, prefix[0..])) |idx| {
            const out_rel_path = line[idx + prefix.len + 1 ..];
            const out_rel_path_stripped = mem.trim(u8, out_rel_path, " \\");
            const dirname = fs.path.dirname(out_rel_path_stripped) orelse ".";
            const maybe_dir = try dirs.getOrPut(dirname);
            if (!maybe_dir.found_existing) {
                maybe_dir.entry.value = try dest_dir.makeOpenPath(dirname, .{});
            }
            const basename = fs.path.basename(out_rel_path_stripped);

            const line_stripped = mem.trim(u8, line, " \\");
            const abs_dirname = fs.path.dirname(line_stripped).?;
            var orig_subdir = try fs.cwd().openDir(abs_dirname, .{});
            defer orig_subdir.close();

            try orig_subdir.copyFile(basename, maybe_dir.entry.value, basename, .{});
        }
    }

    var dir_it = dirs.iterator();
    while (dir_it.next()) |entry| {
        entry.value.close();
    }
}

fn installHeaders(allocator: *Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        try io.getStdErr().writeAll("install: no destination path specified");
        process.exit(1);
    }

    const install_path = args[0];
    var install_dir = fs.cwd().openDir(install_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            const msg = try std.fmt.allocPrint(allocator, "install: installation path '{}' not found or not a directory", .{install_path});
            try io.getStdErr().writeAll(msg);
            process.exit(1);
        },
        else => return err,
    };
    defer install_dir.close();

    var path_table = PathTable.init(allocator);
    var hash_to_contents = HashToContents.init(allocator);

    var savings = FindResult{};
    inline for (targets) |target| {
        const res = try findDuplicates(target, allocator, headers_source_prefix, &path_table, &hash_to_contents);
        savings.max_bytes_saved += res.max_bytes_saved;
        savings.total_bytes += res.total_bytes;
    }

    std.log.warn("summary: {Bi:2} could be reduced to {Bi:2}", .{
        savings.total_bytes,
        savings.total_bytes - savings.max_bytes_saved,
    });

    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    var missed_opportunity_bytes: usize = 0;
    // Iterate path_table. For each path, put all the hashes into a list. Sort by hit_count.
    // The hash with the highest hit_count gets to be the "generic" one. Everybody else
    // gets their header in a separate arch directory.
    var path_it = path_table.iterator();
    while (path_it.next()) |path_kv| {
        var contents_list = std.ArrayList(*Contents).init(allocator);
        {
            var hash_it = path_kv.value.iterator();
            while (hash_it.next()) |hash_kv| {
                const contents = &hash_to_contents.getEntry(hash_kv.value).?.value;
                try contents_list.append(contents);
            }
        }
        std.sort.sort(*Contents, contents_list.items, {}, Contents.hitCountLessThan);
        const best_contents = contents_list.popOrNull().?;
        if (best_contents.hit_count > 1) {
            // Put it in `any-macos-gnu`.
            const full_path = try fs.path.join(allocator, &[_][]const u8{ common_name, path_kv.key });
            try tmp.dir.makePath(fs.path.dirname(full_path).?);
            try tmp.dir.writeFile(full_path, best_contents.bytes);
            best_contents.is_generic = true;
            while (contents_list.popOrNull()) |contender| {
                if (contender.hit_count > 1) {
                    const this_missed_bytes = contender.hit_count * contender.bytes.len;
                    missed_opportunity_bytes += this_missed_bytes;
                    std.debug.warn("Missed opportunity ({Bi:2}): {}\n", .{ this_missed_bytes, path_kv.key });
                } else break;
            }
        }
        var hash_it = path_kv.value.iterator();
        while (hash_it.next()) |hash_kv| {
            const contents = &hash_to_contents.getEntry(hash_kv.value).?.value;
            if (contents.is_generic) continue;

            const target = hash_kv.key;
            const target_name = try target.name(allocator);
            const full_path = try fs.path.join(allocator, &[_][]const u8{ target_name, path_kv.key });
            try tmp.dir.makePath(fs.path.dirname(full_path).?);
            try tmp.dir.writeFile(full_path, contents.bytes);
        }
    }

    inline for (targets) |target| {
        const target_name = try target.name(allocator);
        try install_dir.deleteTree(target_name);
    }
    try install_dir.deleteTree(common_name);

    var tmp_it = tmp.dir.iterate();
    while (try tmp_it.next()) |entry| {
        switch (entry.kind) {
            .Directory => {
                const sub_dir = try tmp.dir.openDir(entry.name, .{});
                const install_sub_dir = try install_dir.makeOpenPath(entry.name, .{});
                try copyDirAll(sub_dir, install_sub_dir);
            },
            else => {
                std.log.warn("unexpected file format: not a directory: '{}'", .{entry.name});
            },
        }
    }
}

const FindResult = struct {
    max_bytes_saved: usize = 0,
    total_bytes: usize = 0,
};

fn findDuplicates(
    comptime target: Target,
    allocator: *Allocator,
    dest_path: []const u8,
    path_table: *PathTable,
    hash_to_contents: *HashToContents,
) !FindResult {
    var result = FindResult{};

    const target_name = try target.name(allocator);
    const target_include_dir = try fs.path.join(allocator, &[_][]const u8{ dest_path, target_name });
    var dir_stack = std.ArrayList([]const u8).init(allocator);
    try dir_stack.append(target_include_dir);

    while (dir_stack.popOrNull()) |full_dir_name| {
        var dir = fs.cwd().openDir(full_dir_name, .{}) catch |err| switch (err) {
            error.FileNotFound => break,
            error.AccessDenied => break,
            else => return err,
        };
        defer dir.close();

        var dir_it = dir.iterate();

        while (try dir_it.next()) |entry| {
            const full_path = try fs.path.join(allocator, &[_][]const u8{ full_dir_name, entry.name });
            switch (entry.kind) {
                .Directory => try dir_stack.append(full_path),
                .File => {
                    const rel_path = try fs.path.relative(allocator, target_include_dir, full_path);
                    const max_size = 2 * 1024 * 1024 * 1024;
                    const raw_bytes = try fs.cwd().readFileAlloc(allocator, full_path, max_size);
                    const trimmed = mem.trim(u8, raw_bytes, " \r\n\t");
                    result.total_bytes += raw_bytes.len;
                    const hash = try allocator.alloc(u8, 32);
                    var hasher = Blake3.init(.{});
                    hasher.update(rel_path);
                    hasher.update(trimmed);
                    hasher.final(hash);
                    const gop = try hash_to_contents.getOrPut(hash);
                    if (gop.found_existing) {
                        result.max_bytes_saved += raw_bytes.len;
                        gop.entry.value.hit_count += 1;
                        std.log.warn("duplicate: {} {} ({Bi:2})", .{
                            target_name,
                            rel_path,
                            raw_bytes.len,
                        });
                    } else {
                        gop.entry.value = Contents{
                            .bytes = trimmed,
                            .hit_count = 1,
                            .hash = hash,
                            .is_generic = false,
                        };
                    }
                    const path_gop = try path_table.getOrPut(rel_path);
                    const target_to_hash = if (path_gop.found_existing) path_gop.entry.value else blk: {
                        const ptr = try allocator.create(TargetToHash);
                        ptr.* = TargetToHash.init(allocator);
                        path_gop.entry.value = ptr;
                        break :blk ptr;
                    };
                    try target_to_hash.putNoClobber(target, hash);
                },
                else => std.log.warn("install: unexpected file: {}", .{full_path}),
            }
        }
    }

    return result;
}

fn copyDirAll(source: fs.Dir, dest: fs.Dir) anyerror!void {
    var it = source.iterate();
    while (try it.next()) |next| {
        switch (next.kind) {
            .Directory => {
                var sub_dir = try dest.makeOpenPath(next.name, .{});
                var sub_source = try source.openDir(next.name, .{});
                defer {
                    sub_dir.close();
                    sub_source.close();
                }
                try copyDirAll(sub_source, sub_dir);
            },
            .File => {
                var source_file = try source.openFile(next.name, .{});
                var dest_file = try dest.createFile(next.name, .{});
                defer {
                    source_file.close();
                    dest_file.close();
                }
                const stat = try source_file.stat();
                const ncopied = try source_file.copyRangeAll(0, dest_file, 0, stat.size);
                assert(ncopied == stat.size);
            },
            else => |kind| {
                std.log.warn("install: unexpected file kind '{}' will be ignored", .{kind});
            },
        }
    }
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena.allocator;

    const args = try std.process.argsAlloc(allocator);
    return mainArgs(allocator, args);
}
