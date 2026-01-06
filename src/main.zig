const std = @import("std");
const sxr = @import("sxr");

pub fn main() !void {
    // Heap
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const allocator = da.allocator();

    // CLI Args
    var args_iter = try std.process.argsWithAllocator(allocator);
    _ = args_iter.skip();

    const path_input = args_iter.next();
    if (path_input == null) {
        std.debug.print("No path provided to extract\n", .{});
        std.process.exit(1);
    }

    // FS Setup
    const cwd = std.fs.cwd();
    cwd.makeDir("output") catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    // Processing
    const input_basename = std.fs.path.basename(path_input.?);
    if (std.mem.eql(u8, input_basename, "pkg.json")) {
        // Load a full pkg.json
        const pkg_dir_path = std.fs.path.dirname(path_input.?).?;

        var pkg_dir: std.fs.Dir = undefined;
        if (std.fs.path.isAbsolute(pkg_dir_path)) {
            pkg_dir = try std.fs.openDirAbsolute(pkg_dir_path, .{});
        } else {
            pkg_dir = try std.fs.cwd().openDir(pkg_dir_path, .{});
        }
        defer pkg_dir.close();

        var pkg: sxr.Package = try .loadDir(allocator, pkg_dir);
        defer pkg.deinit();

        cwd.makePath("output/main") catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };

        var main_output = try cwd.openDir("output/main", .{});
        defer main_output.close();
        try saveEntities(allocator, pkg.mainsxr.entities.items, main_output);

        for (pkg.sxrlist.items) |sxr_item| {
            const sxr_item_path = try std.fmt.allocPrint(
                allocator,
                "output/{s}",
                .{sxr_item.name},
            );
            defer allocator.free(sxr_item_path);

            cwd.makePath(sxr_item_path) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                }
            };
            var sxr_item_output = try cwd.openDir(sxr_item_path, .{});
            defer sxr_item_output.close();

            cwd.makePath("output/main") catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                }
            };

            try saveEntities(allocator, sxr_item.entities.items, sxr_item_output);
        }
    } else if (std.mem.endsWith(u8, input_basename, ".sxr")) {
        // Load a single sxr
        var sxr_file: std.fs.File = undefined;
        if (std.fs.path.isAbsolute(path_input.?)) {
            sxr_file = try std.fs.openFileAbsolute(path_input.?, .{});
        } else {
            sxr_file = try std.fs.cwd().openFile(path_input.?, .{});
        }

        var basename_split = std.mem.splitScalar(u8, input_basename, '.');
        const filename = basename_split.first();

        var loaded_sxr: sxr.Sxr = try .loadFile(allocator, sxr_file);
        defer loaded_sxr.deinit();
        loaded_sxr.name = filename;

        const output_path = try std.fmt.allocPrint(
            allocator,
            "output/{s}",
            .{loaded_sxr.name},
        );
        defer allocator.free(output_path);

        cwd.makePath(output_path) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };

        var output_dir = try cwd.openDir(output_path, .{});
        defer output_dir.close();
        try saveEntities(allocator, loaded_sxr.entities.items, output_dir);
    } else {
        std.debug.print("Seemingly invalid input file (based on names)\n", .{});
    }
}

fn saveEntities(
    allocator: std.mem.Allocator,
    entities: []sxr.Entity,
    output_dir: std.fs.Dir,
) !void {
    for (entities) |entity| {
        // if (entity.child_count != 0) {
        //     // A folder named "" i believe is just the root folder (and usually first)
        //     std.debug.print(
        //         \\Folder "{s}" - {} entities\n
        //         \\
        //         , .{entity.name, entity.child_count},
        //     );
        // }
        if (entity.data == null) continue;

        const name = if (entity.name.len == 0) "unnamed" else entity.name;
        const extension = if (entity.extension) |ext| ext else "bin";
        const entity_path = try std.fmt.allocPrint(
            allocator,
            "{s}.{s}",
            .{ name, extension },
        );
        defer allocator.free(entity_path);

        const entity_file = try output_dir.createFile(entity_path, .{});
        defer entity_file.close();

        _ = try entity_file.write(entity.data.?);
    }
}
