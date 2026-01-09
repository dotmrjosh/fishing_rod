const std = @import("std");
const lz4 = @cImport({
    @cInclude("lz4.h");
});

const Entity = @This();

pub const Compression = enum(u8) {
    none = 0b0000,
    zlib = 0b0110,
    lz4 = 0b1010,
};

allocator: std.mem.Allocator,
name: []const u8,
child_count: u16,
data: ?[]const u8,
extension: ?[]const u8 = null,
type: Compression,

/// This is parsing an entity buffer not including the u16 size
pub fn parseBuf(allocator: std.mem.Allocator, entity_buf: []const u8, sxr_buf: []const u8) !Entity {
    var entity_reader: std.io.Reader = .fixed(entity_buf);
    const child_count = try entity_reader.takeInt(u16, .big);
    const name_size = try entity_reader.takeInt(u16, .big);
    const name = try entity_reader.readAlloc(allocator, name_size);

    const unk_a = try entity_reader.readAlloc(allocator, 8); // unknown area
    defer allocator.free(unk_a);

    const data_offset = try entity_reader.takeInt(u64, .big);
    const data_size = try entity_reader.takeInt(u32, .big);

    const encrypted = try entity_reader.takeInt(u8, .big) != 0;
    const compression = try entity_reader.takeEnum(Compression, .big);

    const decompressed_size = try entity_reader.takeInt(u32, .big);

    // std.debug.print(
    //     \\child_count: {}
    //     \\name_size: {}
    //     \\name: {s}
    //     \\unk_a: {any}
    //     \\data_offset: {}
    //     \\data_size: {}
    //     \\encrypted: {}
    //     \\compression: {}
    //     \\decompressed_size: {}
    //     \\
    // ,
    //     .{
    //         child_count,
    //         name_size,
    //         name,
    //         unk_a,
    //         data_offset,
    //         data_size,
    //         encrypted,
    //         compression,
    //         decompressed_size,
    //     },
    // );
    // defer std.debug.print("\n", .{});

    if (data_size > 0) {
        var data: []u8 = try allocator.dupe(
            u8,
            sxr_buf[data_offset..(data_offset + data_size)],
        );

        if (encrypted) {
            decryptEntity(name, data);
        }

        if (compression != .none) {
            const comp_data = data;
            defer allocator.free(comp_data);

            switch (compression) {
                .zlib => data = decompressZLib(allocator, comp_data) catch
                    try allocator.dupe(u8, comp_data),
                .lz4 => data = decompressLZ4(
                    allocator,
                    comp_data,
                    data_size,
                    decompressed_size,
                ) catch
                    try allocator.dupe(u8, comp_data),
                .none => unreachable,
            }
        }

        const extension = findExtension(data);

        return .{
            .allocator = allocator,
            .name = name,
            .child_count = child_count,
            .data = data,
            .extension = extension,
            .type = compression,
        };
    } else {
        return .{
            .allocator = allocator,
            .name = name,
            .child_count = child_count, // will be > 0
            .data = null,
            .extension = null,
            .type = compression, // probably none
        };
    }

    unreachable;
}

fn decompressZLib(allocator: std.mem.Allocator, compressed_data: []const u8) ![]u8 {
    errdefer |err| {
        std.debug.print("zlib decompress err: {any}\n", .{err});
    }

    var data_reader: std.io.Reader = .fixed(compressed_data);
    var deco_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var deco: std.compress.flate.Decompress = .init(
        &data_reader,
        .zlib,
        &deco_buf,
    );
    var out: std.io.Writer.Allocating = .init(allocator);
    _ = try deco.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

fn decompressLZ4(
    allocator: std.mem.Allocator,
    compressed_data: []const u8,
    compressed_size: usize,
    decompressed_size: usize,
) ![]u8 {
    errdefer |err| {
        std.debug.print("lz4 decompress err: {any}\n", .{err});
    }

    // WARN: C will mutate this data even though we've defined it as constant
    const decompressed_data = try allocator.alloc(u8, decompressed_size);
    const result = lz4.LZ4_decompress_safe(
        compressed_data.ptr,
        decompressed_data.ptr,
        @intCast(compressed_size),
        @intCast(decompressed_size),
    );

    if (@as(usize, @intCast(result)) != decompressed_size)
        return error.LZ4DecompressionError;

    return decompressed_data;
}

pub fn decryptEntity(name: []const u8, payload: []u8) void {
    if (payload.len == 0) return;

    const stored_size: u32 = @intCast(payload.len);
    const key32: u32 = std.hash.Fnv1a_32.hash(name);

    const seed: u32 = (@as(u32, 137) *% stored_size) ^ key32 ^ 0xC413A951;

    const t: u32 = seed ^ (seed << 11);
    const v31: u32 = t ^ (t >> 8);

    var v32: u32 = v31 ^ (v31 >> 19) ^ 0x52F53BE0;
    var v34: u32 = v31 ^ 0xDCB47C50;
    var v35: u32 = (v31 >> 19) ^ v32 ^ 0x4D9D51E6;
    var v36: u32 = 0xDCB467C6;

    const nwords: usize = (payload.len + 3) / 4;
    var i: usize = 0;
    while (i < nwords) : (i += 1) {
        const base: usize = i * 4;
        const rem: usize = payload.len - base;
        const take: usize = if (rem >= 4) 4 else rem;

        var word: u32 = 0;
        if (take == 4) {
            const p4: *const [4]u8 = @ptrCast(payload[base .. base + 4].ptr);
            word = std.mem.readInt(u32, p4, .little);
        } else {
            var tmp: [4]u8 = .{ 0, 0, 0, 0 };
            std.mem.copyForwards(u8, tmp[0..take], payload[base .. base + take]);
            word = std.mem.readInt(u32, &tmp, .little);
        }

        const x: u32 = v36 ^ (v36 << 11);
        const ks: u32 = v35 ^ x ^ (x >> 8) ^ (v35 >> 19);

        word ^= ks;

        v36 = v34;
        v34 = v32;
        v32 = v35;
        v35 = ks;

        var out: [4]u8 = undefined;
        std.mem.writeInt(u32, &out, word, .little);
        std.mem.copyForwards(u8, payload[base .. base + take], out[0..take]);
    }
}

fn findExtension(buf: ?[]const u8) ?[]const u8 {
    if (buf) |b| {
        // Images

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a },
        )) return "png";

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0xff, 0xd8, 0xff, 0xdb },
        ) or std.mem.startsWith(
            u8,
            b,
            &.{ 0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01 },
        ) or std.mem.startsWith(
            u8,
            b,
            &.{ 0xff, 0xd8, 0xff, 0xee },
        )) return "jpg";

        // Media
        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x4F, 0x67, 0x67, 0x53 },
        )) return "ogg";

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x52, 0x49, 0x46, 0x46 }, // RIFF
        ) and std.mem.startsWith(
            u8,
            b[8..12],
            &.{ 0x57, 0x41, 0x56, 0x45 }, // WAVE
        )) return "wav";

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x52, 0x49, 0x46, 0x46 }, // RIFF
        ) and std.mem.startsWith(
            u8,
            b[8..12],
            &.{ 0x41, 0x56, 0x49, 0x20 }, // AVI
        )) return "avi";

        // These are some kind of scene/mesh/animation data in an unknown format

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x53, 0x4D, 0x4F, 0x54 },
        )) return "smot";

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x53, 0x4d, 0x44, 0x4c },
        ) or std.mem.startsWith(
            u8,
            b[2..6],
            &.{ 0x53, 0x4d, 0x44, 0x4c },
        )) return "smdl";
    }

    return null;
}

pub fn deinit(self: *Entity) void {
    self.allocator.free(self.name);
    if (self.data) |data| self.allocator.free(data);
}
