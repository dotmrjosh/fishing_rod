const std = @import("std");

const Smdl = @This();

const Bitsize = enum(u8) {
    u32 = 0,
    u16 = 1,
};

pub const Block = struct {
    type: u32,
    bitsize: Bitsize,
    components: u8,
    check: u32,
};

allocator: std.mem.Allocator,
blocks: []Block,
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
        .allocator = allocator,
        .blocks = undefined,
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

    smdl.blocks = try allocator.alloc(Block, block_count);

    for (0..(block_count)) |block_idx| {
        const block_type = try smdl_reader.takeInt(u16, .big);
        const bitsize = try smdl_reader.takeEnum(Bitsize, .big);
        const components = try smdl_reader.takeInt(u8, .big);
        const check = try smdl_reader.takeInt(u32, .big); // this should be the same in every block
        const maybe_hint = try smdl_reader.takeInt(u16, .big);
        const unknown_bb = try smdl_reader.takeInt(u16, .big);
        const count = try smdl_reader.takeInt(u16, .big);

        smdl.blocks[block_idx] = .{
            .type = block_type,
            .bitsize = bitsize,
            .components = components,
            .check = check,
        };

        // TODO: actually perform a check against the last block to be sure its parsing
        // correctly
        _ = maybe_hint;
        _ = unknown_bb;

        switch (block_type) {
            // vertex positions
            1 => {
                // TODO: This assumes only 1 positions block which could be wrong
                smdl.positions = try allocator.alloc([3]f32, count);
                for (0..count) |i| {
                    const x: f32 = @bitCast(try smdl_reader.takeInt(u32, .big));
                    const y: f32 = @bitCast(try smdl_reader.takeInt(u32, .big));
                    const z: f32 = @bitCast(try smdl_reader.takeInt(u32, .big));

                    smdl.positions[i] = [3]f32{ x, y, z };
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

        smdl.tri_idx_b = try allocator.alloc([3]u16, idx_count / 3);

        for (0..(idx_count / 3)) |i| {
            const a = try idx_reader.takeInt(u16, .big);
            const b = try idx_reader.takeInt(u16, .big);
            const c = try idx_reader.takeInt(u16, .big);

            smdl.tri_idx_b[i] = [3]u16{ a, b, c };
        }
    }

    return smdl;
}

pub fn deinit(self: *Smdl) void {
    self.allocator.free(self.blocks);
    self.allocator.free(self.positions);
    self.allocator.free(self.tri_idx_b);
}

pub fn generateObj(self: Smdl, allocator: std.mem.Allocator) ![]const u8 {
    var obj: std.io.Writer.Allocating = .init(allocator);
    defer obj.deinit();

    var line_buf: [256]u8 = undefined;
    for (self.positions) |pos| {
        const v = try std.fmt.bufPrint(
            &line_buf,
            "v {} {} {}\n",
            .{ pos[0], pos[1], pos[2] },
        );
        _ = try obj.writer.write(v);
    }

    for (self.tri_idx_b) |tib| {
        const v = try std.fmt.bufPrint(
            &line_buf,
            "f {} {} {}\n",
            // we need to add 1 since obj index starts at 1
            .{ tib[0] + 1, tib[1] + 1, tib[2] + 1 },
        );
        _ = try obj.writer.write(v);
    }

    return try obj.toOwnedSlice();
}
