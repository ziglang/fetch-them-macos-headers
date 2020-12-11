const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const tmpDir = std.testing.tmpDir;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = &general_purpose_allocator.allocator;
const Allocator = mem.Allocator;

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

const out_path = @tagName(builtin.arch) ++ "-macos-gnu";

fn mainArgs(all_args: []const []const u8) !void {
    const args = all_args[1..];
    if (args.len > 0) {
        const first_arg = args[0];
        if (mem.eql(u8, first_arg, "--help") or mem.eql(u8, first_arg, "-h")) {
            try io.getStdOut().writeAll(usage);
            return;
        } else if (mem.eql(u8, first_arg, "install")) {
            return installHeaders(args[1..]);
        } else {
            return fetchHeaders(args[1..]);
        }
    } else {
        return fetchHeaders(args);
    }
}

fn fetchHeaders(args: []const []const u8) !void {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);

    const tmp_filename = "headers";
    const tmp_file_path = try fs.path.join(gpa, &[_][]const u8{ tmp_path, tmp_filename });
    defer gpa.free(tmp_file_path);

    const headers_list_filename = "headers.o.d";
    const headers_list_path = try fs.path.join(gpa, &[_][]const u8{ tmp_path, headers_list_filename });
    defer gpa.free(headers_list_path);

    var argv = std.ArrayList([]const u8).init(std.heap.page_allocator);
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
        .allocator = gpa,
        .argv = argv.items,
    });
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (res.stderr.len != 0) {
        std.debug.print("{}\n", .{res.stderr});
    }

    // Read in the contents of `upgrade.o.d`
    const headers_list_file = try tmp.dir.openFile(headers_list_filename, .{});
    defer headers_list_file.close();

    // Create out dir
    var out_dir = try fs.cwd().makeOpenPath(out_path, .{});
    var dirs = std.StringHashMap(fs.Dir).init(gpa);
    defer dirs.deinit();
    try dirs.putNoClobber(".", out_dir);

    const headers_list_str = try headers_list_file.reader().readAllAlloc(gpa, std.math.maxInt(usize));
    defer gpa.free(headers_list_str);
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
                maybe_dir.entry.value = try out_dir.makeOpenPath(dirname, .{});
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

fn installHeaders(args: []const []const u8) !void {
    if (args.len < 1) {
        try io.getStdErr().writeAll("install: no destination path specified");
        process.exit(1);
    }

    var source_dir = fs.cwd().openDir(out_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const msg = try std.fmt.allocPrint(gpa, "install: source path '{}' not found; did you forget to run `fetch_them_macos_headers` first?", .{out_path});
            try io.getStdErr().writeAll(msg);
            process.exit(1);
        },
        else => return err,
    };
    defer source_dir.close();

    const dest_path = args[0];
    var dest_dir = fs.cwd().openDir(dest_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            const msg = try std.fmt.allocPrint(gpa, "install: destination path '{}' not found or not a directory", .{dest_path});
            try io.getStdErr().writeAll(msg);
            process.exit(1);
        },
        else => return err,
    };
    defer dest_dir.close();

    var dest_sub_path = try dest_dir.makeOpenPath(out_path, .{});
    defer dest_sub_path.close();

    try copyDirAll(source_dir, dest_sub_path);
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
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    return mainArgs(args);
}
