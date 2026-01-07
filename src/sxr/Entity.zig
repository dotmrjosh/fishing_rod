const std = @import("std");

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
    var name = try entity_reader.readAlloc(allocator, name_size);

    const unk_a = try entity_reader.readAlloc(allocator, 8); // unknown area
    defer allocator.free(unk_a);

    const offset = try entity_reader.takeInt(u64, .big);
    const offset_size = try entity_reader.takeInt(u32, .big);

    const encrypted = try entity_reader.takeInt(u8, .big) != 0;
    const compression = try entity_reader.takeEnum(Compression, .big);

    const compressed = !encrypted and compression == Compression.zlib;
    const decoded_size = try entity_reader.takeInt(u32, .big); // unconfirmed

    std.debug.print(
        \\child_count: {}
        \\name_size: {}
        \\name: {s}
        \\unk_a: {any}
        \\offset: {}
        \\offset_size: {}
        \\encrypted: {}
        \\compression: {}
        \\decoded_size: {}
        \\
        , .{
            child_count,
            name_size,
            name,
            unk_a,
            offset,
            offset_size,
            encrypted,
            compression,
            decoded_size,
        },
    );

    var data: ?[]const u8 = null;

    if (compressed) {
        const comp_data = try allocator.dupe(u8, sxr_buf[offset..(offset + offset_size)]);
        defer allocator.free(comp_data);
        data = try decompressZLib(allocator, comp_data);

        const old_name = name;
        defer allocator.free(old_name);
        name = try std.fmt.allocPrint(allocator, "{s}_deco", .{old_name});
    } else if (offset_size > 0) {
        data = try allocator.dupe(u8, sxr_buf[offset..(offset + offset_size)]);
    } else {
        data = null;
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
}

fn decompressZLib(allocator: std.mem.Allocator, compressed_data: []const u8) ![]const u8 {
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
