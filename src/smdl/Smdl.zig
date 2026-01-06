const std = @import("std");

const Smdl = @This();

const Bitsize = enum(u8) {
    u32 = 0,
    u16 = 1,
};

positions: [][3]f32,
tri_idx_b: [][3]u16,

pub fn loadFile(allocator: std.mem.Allocator, sxr_file: std.fs.File) !Smdl {
    var buf: [1024]u8 = undefined;
    var sxr_reader = sxr_file.reader(&buf);
    const sxr_data = try sxr_reader.interface.readAlloc(
        allocator,
        try sxr_reader.getSize(),
    );
    defer allocator.free(sxr_data);

    return try parseBuf(allocator, sxr_data);
}

pub fn parseBuf(allocator: std.mem.Allocator, smdl_buf: []const u8) !Smdl {
    var smdl: Smdl = .{
        .positions = undefined,
        .tri_idx_b = undefined,
    };
    var smdl_reader: std.io.Reader = .fixed(smdl_buf);

    if (std.mem.eql(u8, try smdl_reader.peek(2), &.{ 0xf3, 0x05 })) {
        return error.WrappedSmdlNotImplemented;
    }

    // header checks
    if (!std.mem.eql(
        u8,
        try smdl_reader.take(4),
        "SMDL",
    )) return error.InvalidSmdlHeader;

    const maybe_version = try smdl_reader.takeInt(u16, .big);
    const unknown_a = try smdl_reader.takeInt(u16, .big);
    const block_count = try smdl_reader.takeInt(u16, .big);
    const unknown_b = try smdl_reader.takeInt(u16, .big);
    const maybe_asset_id = try smdl_reader.takeInt(u16, .big);

    _ = maybe_version;
    _ = unknown_a;
    _ = unknown_b;
    _ = maybe_asset_id;

    // std.debug.print(
    //     \\parsing smdl
    //     \\  version: {}
    //     \\  unknown: {b}
    //     \\  block_count: {}
    //     \\  unknown: {b}
    //     \\  asset_id: {}
    //     \\
    // ,
    //     .{
    //         maybe_version,
    //         unknown_a,
    //         block_count,
    //         unknown_b,
    //         maybe_asset_id,
    //     },
    // );

    // var debug_obj = try std.fs.cwd().createFile("debug.obj", .{});
    // defer debug_obj.close();

    for (0..(block_count)) |_| {
        const block_type = try smdl_reader.takeInt(u16, .big);
        const bitsize = try smdl_reader.takeEnum(Bitsize, .big);
        const components = try smdl_reader.takeInt(u8, .big);
        const check = try smdl_reader.takeInt(u32, .big); // this should be the same in every block
        const maybe_hint = try smdl_reader.takeInt(u16, .big);
        const unknown_bb = try smdl_reader.takeInt(u16, .big);
        const count = try smdl_reader.takeInt(u16, .big);

        // TODO: actually perform a check against the last block to be sure its parsing
        // correctly
        _ = check;
        _ = maybe_hint;
        _ = unknown_bb;

        // std.debug.print(
        //     \\  block {}
        //     \\    kind:     0b{b:0>8} ({})
        //     \\    bitsize:  0b{b:0>8} ({})
        //     \\    compnts:  0b{b:0>8} ({})
        //     \\    check:    {x}
        //     \\    hint:     {}
        //     \\    unknown:  0b{b}
        //     \\    count:    {}
        //     \\
        // ,
        //     .{
        //         block_idx,
        //         block_type,
        //         block_type,
        //         bitsize,
        //         bitsize,
        //         components,
        //         components,
        //         check,
        //         maybe_hint,
        //         unknown_bb,
        //         count,
        //     },
        // );

        switch (block_type) {
            // vertex positions
            1 => {
                var line_buf: [2048]u8 = undefined;
                for (0..count) |_| {
                    const x: f32 = @bitCast(try smdl_reader.takeInt(u32, .big));
                    const y: f32 = @bitCast(try smdl_reader.takeInt(u32, .big));
                    const z: f32 = @bitCast(try smdl_reader.takeInt(u32, .big));

                    const vertex = try std.fmt.bufPrint(
                        &line_buf,
                        "v {} {} {}\n",
                        .{ x, y, z },
                    );
                    _ = try debug_obj.write(vertex);
                }
            },
            else => {
                if (components == 4) {
                    smdl_reader.toss(count * components);
                } else {
                    switch (bitsize) {
                        .u32 => smdl_reader.toss(count * 4 * components), // VecX(u32)
                        .u16 => smdl_reader.toss(count * 2 * components), // VecX(u16)
                    }
                }
            },
        }
    }

    {
        var idx_buf: [100_000]u8 = undefined;
        var idx_writer: std.io.Writer = .fixed(&idx_buf);
        const idx_len = try smdl_reader.streamRemaining(&idx_writer);
        const idx_data = idx_buf[0..idx_len];

        var idx_reader: std.io.Reader = .fixed(idx_data);

        const padding = try idx_reader.takeInt(u32, .big);
        _ = padding;
        idx_reader.toss(9);
        const idx_count = try idx_reader.takeInt(u32, .big);

        // std.debug.print(
        //     \\  idx
        //     \\    padding: 0b{b:0>32}
        //     \\
        // ,
        //     .{
        //         padding,
        //     },
        // );

        var line_buf: [2048]u8 = undefined;
        for (0..(idx_count / 3)) |_| {
            const a = try idx_reader.takeInt(u16, .big);
            const b = try idx_reader.takeInt(u16, .big);
            const c = try idx_reader.takeInt(u16, .big);

            const index = try std.fmt.bufPrint(
                &line_buf,
                "f {} {} {}\n",
                .{ a + 1, b + 1, c + 1 },
            );
            _ = try debug_obj.write(index);
        }

        // const leftovers = try idx_reader.discardRemaining();
        // std.debug.print("bits leftover {}\n", .{leftovers});
    }

    return .{};
}

pub fn deinit(self: *Smdl) void {
    _ = self;
}
