const std = @import("std");
const mem = std.mem;
const tmpDir = std.testing.tmpDir;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = &gpa.allocator;

pub fn main() !void {
    var tmp = tmpDir(.{});
    defer tmp.cleanup();

    const tmp_out_file = try std.fs.path.join(alloc, &[_][]const u8{ "zig-cache", "tmp", tmp.sub_path[0..], "tmp" });
    defer alloc.free(tmp_out_file);

    const out_loc_list = try std.fs.path.join(alloc, &[_][]const u8{ "zig-cache", "tmp", tmp.sub_path[0..], "upgrade.o.d" });
    defer alloc.free(out_loc_list);

    // TODO instead of calling `cc` as a child process here,
    // hook in directly to `zig cc` API.
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = &[_][]const u8{ "cc", "-o", tmp_out_file, "src/upgrade.c", "-MD", "-MV", "-MF", out_loc_list },
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    // Read in the contents of `upgrade.o.d`
    const loc_list_file = try tmp.dir.openFile("upgrade.o.d", .{});
    defer loc_list_file.close();

    // Create out dir
    var out_dir = try std.fs.cwd().makeOpenPath("x86_64-macos-gnu", .{});
    defer out_dir.close();

    const loc_list_str = try loc_list_file.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(loc_list_str);
    const prefix = "/usr/include";
    var it = mem.split(loc_list_str, "\n");
    while (it.next()) |line| {
        if (mem.lastIndexOf(u8, line, "clang") != null) continue;
        if (mem.lastIndexOf(u8, line, prefix[0..])) |idx| {
            const out_rel_path = line[idx + prefix.len + 1 ..];
            const out_rel_path_stripped = mem.trim(u8, out_rel_path, " \\");
            var dir = if (std.fs.path.dirname(out_rel_path_stripped)) |dirname|
                try out_dir.makeOpenPath(dirname, .{})
            else
                try std.fs.cwd().makeOpenPath("x86_64-macos-gnu", .{});
            defer dir.close();
            const basename = std.fs.path.basename(out_rel_path_stripped);

            const line_stripped = mem.trim(u8, line, " \\");
            const abs_dirname = std.fs.path.dirname(line_stripped).?;
            var orig_subdir = try std.fs.cwd().openDir(abs_dirname, .{});
            defer orig_subdir.close();

            try orig_subdir.copyFile(basename, dir, basename, .{});
        }
    }
}
