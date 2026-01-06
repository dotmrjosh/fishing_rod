const std = @import("std");
const Sxr = @import("./Sxr.zig");

const Package = @This();

const PkgJSON = struct {
    const PkgSxrMeta = struct {
        install: bool = true,
        md5: []const u8,
        size: i64,
        version: i16 = 0,
        sxrname: []const u8 = "",
        checksum: i64 = 0,
    };

    version: i16,
    mainsxr: PkgSxrMeta,
    sxrlist: []const PkgSxrMeta,
};

allocator: std.mem.Allocator,
mainsxr: Sxr,
sxrlist: std.array_list.Aligned(Sxr, null),

pub fn loadDir(allocator: std.mem.Allocator, dir: std.fs.Dir) !Package {
    // Re-open the directory with the guaranteed ability to iterate
    var iterable_dir = try dir.openDir(".", .{ .iterate = true });
    defer iterable_dir.close();

    var path_walker = try iterable_dir.walk(allocator);
    defer path_walker.deinit();

    var mainsxr: Sxr = undefined;
    var sxrlist: std.array_list.Aligned(Sxr, null) = try .initCapacity(allocator, 40);

    while (try path_walker.next()) |entry| {
        // We should only have files
        if (entry.kind != .file) continue;

        // Fuck you macos
        if (std.mem.eql(u8, entry.basename, ".DS_Store")) continue;

        const file = try iterable_dir.openFile(entry.path, .{ .mode = .read_only });
        defer file.close();
        const file_stat = try file.stat();

        if (std.mem.eql(u8, entry.basename, "version")) {
            var buf: [8]u8 = undefined;
            var reader = file.reader(&buf);

            const version_str = reader.interface.readAlloc(
                allocator,
                file_stat.size,
            ) catch return error.VersionReadFailed;
            defer allocator.free(version_str);

            const version = try std.fmt.parseInt(i16, version_str, 10);
            _ = version;
        }

        if (std.mem.eql(u8, entry.basename, "pkg.json")) {
            var buf: [8]u8 = undefined;
            var reader = file.reader(&buf);

            const pkg_json_str = reader.interface.readAlloc(
                allocator,
                file_stat.size,
            ) catch return error.PkgReadFailed;
            defer allocator.free(pkg_json_str);

            const pkg_json: std.json.Parsed(PkgJSON) = std.json.parseFromSlice(
                PkgJSON,
                allocator,
                pkg_json_str,
                .{},
            ) catch return error.PkgParseFailed;
            defer pkg_json.deinit();

            // main.sxr
            {
                const mainsxr_file = try dir.openFile("main.sxr", .{ .mode = .read_only });
                var sxr_buf: [1024]u8 = undefined;
                var mainsxr_file_reader = mainsxr_file.reader(&sxr_buf);
                const mainsxr_file_data = try mainsxr_file_reader.interface.readAlloc(
                    allocator,
                    try mainsxr_file_reader.getSize(),
                );
                defer allocator.free(mainsxr_file_data);

                mainsxr = try .parseBuf(allocator, mainsxr_file_data);
                mainsxr.name = "main";
            }

            // sxrlist
            {
                for (pkg_json.value.sxrlist) |sxr_meta| {
                    const path = try std.fmt.allocPrint(
                        allocator,
                        "{s}-0{x}.sxr", // WARN: Hacked 0 padding prefix but no files go out the threshold
                        .{sxr_meta.sxrname, sxr_meta.version},
                    );
                    defer allocator.free(path);

                    const sxr_file = try dir.openFile(path, .{ .mode = .read_only });
                    var sxr_buf: [1024]u8 = undefined;
                    var sxr_file_reader = sxr_file.reader(&sxr_buf);

                    const sxr_file_data = try sxr_file_reader.interface.readAlloc(
                        allocator,
                        try sxr_file_reader.getSize(),
                    );
                    defer allocator.free(sxr_file_data);

                    var sxr: Sxr = try .parseBuf(allocator, sxr_file_data);
                    sxr.name = try std.fmt.allocPrint(
                        allocator,
                        "{s}-0{x}",
                        .{sxr_meta.sxrname, sxr_meta.version},
                    );
                    try sxrlist.append(allocator, sxr);
                }
            }
        }
    }

    return .{
        .allocator = allocator,
        .mainsxr = mainsxr,
        .sxrlist = sxrlist,
    };
}

pub fn deinit(self: *Package) void {
    self.mainsxr.deinit();
    for (self.sxrlist.items) |*sxr| {
        self.allocator.free(sxr.name);
        sxr.deinit();
    }
    self.sxrlist.deinit(self.allocator);
}
