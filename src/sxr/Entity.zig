const std = @import("std");

const Entity = @This();

pub const EntityType = enum(u8) {
    type_a,
    type_b,
    type_c,
    type_d,
    type_e,
    type_f,
    compressed = 6,
    type_g,
    type_h,
    type_i,
    type_j,
};

allocator: std.mem.Allocator,
name: []const u8,
child_count: u16,
data: ?[]const u8,
extension: ?[]const u8 = null,

/// This is parsing an entity buffer not including the u16 size
pub fn parseBuf(allocator: std.mem.Allocator, entity_buf: []const u8, sxr_buf: []const u8) !Entity {
    var entity_reader: std.io.Reader = .fixed(entity_buf);
    const child_count = try entity_reader.takeInt(u16, .big);
    const name_len = try entity_reader.takeInt(u16, .big);
    var name = try entity_reader.readAlloc(allocator, name_len);

    entity_reader.toss(8); // unknown area

    const offset = try entity_reader.takeInt(u64, .big);
    const offset_size = try entity_reader.takeInt(u32, .big);

    const flags_a = try entity_reader.takeInt(u8, .big);
    const entity_type = try entity_reader.takeEnum(EntityType, .big);

    const compressed = flags_a == 0 and entity_type == EntityType.compressed;
    entity_reader.toss(4); // unknown area

    var data: ?[]const u8 = null;

    if (compressed) {
        const comp_data = try allocator.dupe(u8, sxr_buf[offset..(offset + offset_size)]);
        defer allocator.free(comp_data);
        data = try decompressZLib(allocator, comp_data);

        const old_name = name;
        defer allocator.free(old_name);
        name = try std.fmt.allocPrint(allocator, "deco_{s}", .{old_name});
    } else if (offset_size > 0) {
        data = try allocator.dupe(u8, sxr_buf[offset..(offset + offset_size)]);
    } else {
        data = null;
    }

    if (data) |d| {
        std.debug.print("{x}\n", .{d[0..4]});
    }

    return .{
        .allocator = allocator,
        .name = name,
        .child_count = child_count,
        .data = data,
        .extension = findExtension(data),
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

        // These are some kind of scene/mesh/animation data in a proprietary format

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x53, 0x4D, 0x4F, 0x54 },
        )) return "SMOT";

        if (std.mem.startsWith(
            u8,
            b,
            &.{ 0x53, 0x4D, 0x44, 0x4C },
        )) return "SMDL";
    }

    return null;
}

pub fn deinit(self: *Entity) void {
    self.allocator.free(self.name);
    if (self.data) |data| self.allocator.free(data);
}
