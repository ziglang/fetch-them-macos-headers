const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const tmpDir = std.testing.tmpDir;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = &gpa.allocator;

pub fn main() !void {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    const tmp_filename = "headers";
    const tmp_file_path = try fs.path.join(alloc, &[_][]const u8{ tmp_path, tmp_filename });
    defer alloc.free(tmp_file_path);

    const headers_list_filename = "headers.o.d";
    const headers_list_path = try fs.path.join(alloc, &[_][]const u8{ tmp_path, headers_list_filename });
    defer alloc.free(headers_list_path);

    // TODO instead of calling `cc` as a child process here,
    // hook in directly to `zig cc` API.
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = &[_][]const u8{ "cc", "-o", tmp_file_path, "src/headers.c", "-MD", "-MV", "-MF", headers_list_path },
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    // Read in the contents of `upgrade.o.d`
    const headers_list_file = try tmp.dir.openFile(headers_list_filename, .{});
    defer headers_list_file.close();

    // Create out dir
    var out_dir = try fs.cwd().makeOpenPath("x86_64-macos-gnu", .{});
    var dirs = std.StringHashMap(fs.Dir).init(alloc);
    defer dirs.deinit();
    try dirs.putNoClobber(".", out_dir);

    const headers_list_str = try headers_list_file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(headers_list_str);
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
