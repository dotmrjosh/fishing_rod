const std = @import("std");
const Entity = @import("./Entity.zig");

const Sxr = @This();

pub const Header = struct {
    /// this is the byte offset to the start of the trailer
    trailer_offset: u64, // big endian
    trailer_length: u32, // big endian
    flags: [42]u8,
};

allocator: std.mem.Allocator,
name: []const u8 = "sxr",
header: Header,
entities: std.array_list.Aligned(Entity, null),

pub fn loadFile(allocator: std.mem.Allocator, sxr_file: std.fs.File) !Sxr {
    var buf: [1024]u8 = undefined;
    var sxr_reader = sxr_file.reader(&buf);
    const sxr_data = try sxr_reader.interface.readAlloc(
        allocator,
        try sxr_reader.getSize(),
    );
    defer allocator.free(sxr_data);

    return try parseBuf(allocator, sxr_data);
}

/// Parse sxr data buffer into an Sxr type
pub fn parseBuf(allocator: std.mem.Allocator, sxr_buf: []const u8) !Sxr {
    var aa: std.heap.ArenaAllocator = .init(allocator);
    defer aa.deinit();
    const arena_allocator = aa.allocator();

    var sxr_reader: std.io.Reader = .fixed(sxr_buf);

    // Header checks
    if (!std.mem.eql(
        u8,
        try sxr_reader.readAlloc(arena_allocator, 4),
        "SXR ",
    )) return error.InvalidFileHeader;
    if (!std.mem.eql(
        u8,
        try sxr_reader.readAlloc(arena_allocator, 4),
        "DEFL",
    )) return error.InvalidCrypterHeader;
    if (!std.mem.eql(
        u8,
        try sxr_reader.readAlloc(arena_allocator, 2),
        "&F",
    )) return error.InvalidMagicHeader;

    const trailer_offset = try sxr_reader.takeInt(u64, .big);
    const trailer_length = try sxr_reader.takeInt(u32, .big);
    var flags: [42]u8 = undefined;
    try sxr_reader.readSliceAll(&flags);

    const header: Header = .{
        .trailer_offset = trailer_offset,
        .trailer_length = trailer_length,
        .flags = flags,
    };

    var entities: std.array_list.Aligned(Entity, null) = try .initCapacity(allocator, 40);

    const trailer_data = try decodeTrailerAlloc(
        allocator,
        header,
        sxr_buf[header.trailer_offset..header.trailer_offset+header.trailer_length],
    );
    defer allocator.free(trailer_data);

    var trailer_reader: std.io.Reader = .fixed(trailer_data);
    while (trailer_reader.takeInt(u16, .big)) |size| {
        const entity_buf = try trailer_reader.readAlloc(allocator, size);
        defer allocator.free(entity_buf);
        const entity: Entity = try .parseBuf(allocator, entity_buf, sxr_buf);
        try entities.append(allocator, entity);
    } else |err| {
        switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    return .{
        .allocator = allocator,
        .header = header,
        .entities = entities,
    };
}

pub fn deinit(self: *Sxr) void {
    for (self.entities.items) |*entity| {
        entity.deinit();
    }
    self.entities.deinit(self.allocator);
}

/// Copies the trailer into a new buffer and decodes it
pub fn decodeTrailerAlloc(allocator: std.mem.Allocator, header: Header, trailer: []const u8) ![]const u8 {
    const decoded = try allocator.dupe(u8, trailer);

    try decodeTrailer(header, decoded);
    return decoded;
}

/// Mutates a trailer into it's decoded format
pub fn decodeTrailer(header: Header, trailer: []u8) !void {
    if (header.trailer_length != trailer.len) return error.MismatchHeaderLength;

    var state_a: u32 = undefined;
    var state_b: u32 = undefined;
    var state_c: u32 = undefined;
    var state_d: u32 = undefined;
    var prev_c: u32 = undefined;
    var keystream: u32 = undefined;
    var keystream_parts: [4]u8 = undefined;

    const offset_lo: u32 = @truncate(header.trailer_offset & 0xffffffff);
    const offset_hi: u32 = @truncate(header.trailer_offset >> 32);

    const signmask: u32 = if (((header.trailer_length << 16) & 0x80000000) != 0) 0xffffffff else 0;

    state_a = offset_hi ^ signmask ^ 0x075bcff3;
    state_a ^= state_a << 11;
    state_a ^= (state_a >> 8) ^ 0x0549139a;

    state_b = offset_lo ^ (header.trailer_length << 16) ^ 0x3bec56ae;
    state_b ^= state_b << 11;

    state_c = state_b ^ (state_b >> 8) ^ state_a;
    state_d = state_c ^ (state_a >> 19);
    state_b = state_d ^ 0x8E415C26;
    state_c = state_b ^ (state_c >> 19);
    state_b = state_c ^ (state_b >> 19) ^ 0x4D9D5BB8;

    const words: usize = (header.trailer_length + 3) / 4;
    for (0..words) |word_index| {
        prev_c = state_c;
        state_a = state_a ^ (state_a << 11);
        keystream = state_b ^ state_a ^ (state_a >> 8) ^ (state_b >> 19);

        std.mem.writeInt(u32, &keystream_parts, keystream, .little);

        const base = word_index * 4;
        for (keystream_parts, 0..) |part, i| {
            const trailer_index = base + i;
            if (trailer_index >= trailer.len) break;
            trailer[trailer_index] ^= part;
        }

        state_c = state_b;
        state_a = state_d;
        state_b = keystream;
        state_d = prev_c;
    }
}
