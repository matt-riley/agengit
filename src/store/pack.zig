const std = @import("std");

const fs_mod = @import("../util/fs.zig");
const hash_mod = @import("hash.zig");

pub const Hash = hash_mod.Hash;

const magic = "AGITPK1\n";
const version: u32 = 1;
const fixed_header_len: usize = magic.len + 4;
const entry_header_len: usize = 68;
const no_base_offset = std.math.maxInt(u64);

pub const EntryKind = enum(u8) {
    blob = 1,
    tree = 2,
    step = 3,
    blame = 4,

    pub fn fromString(raw: []const u8) !EntryKind {
        if (std.mem.eql(u8, raw, "blob")) return .blob;
        if (std.mem.eql(u8, raw, "tree")) return .tree;
        if (std.mem.eql(u8, raw, "step")) return .step;
        if (std.mem.eql(u8, raw, "blame")) return .blame;
        return error.UnsupportedPackKind;
    }

    pub fn asString(self: EntryKind) []const u8 {
        return switch (self) {
            .blob => "blob",
            .tree => "tree",
            .step => "step",
            .blame => "blame",
        };
    }
};

pub const Encoding = enum(u8) {
    full = 1,
    delta = 2,

    pub fn asString(self: Encoding) []const u8 {
        return switch (self) {
            .full => "full",
            .delta => "delta",
        };
    }
};

pub const PrefixMatches = struct {
    count: usize = 0,
    hashes: [2]Hash = undefined,
};

pub const PlannedEntry = struct {
    hash: Hash,
    kind: EntryKind,
    raw: []const u8,
    delta_base_index: ?usize = null,
};

pub const WrittenEntry = struct {
    hash: Hash,
    kind: EntryKind,
    offset: u64,
    packed_len: u64,
    unpacked_len: u64,
    encoding: Encoding,
    base_offset: ?u64 = null,
    base_hash: ?Hash = null,
    depth: u16 = 0,
    crc32: u32,
};

pub const WriteResult = struct {
    pack_name: []u8,
    entries: []WrittenEntry,
    file_size: u64,
    already_exists: bool = false,

    pub fn deinit(self: *WriteResult, gpa: std.mem.Allocator) void {
        gpa.free(self.pack_name);
        gpa.free(self.entries);
        self.* = undefined;
    }
};

pub const ReadResult = struct {
    pack_name: []u8,
    entry: WrittenEntry,
    raw: []u8,

    pub fn deinit(self: *ReadResult, gpa: std.mem.Allocator) void {
        gpa.free(self.pack_name);
        gpa.free(self.raw);
        self.* = undefined;
    }
};

pub const ParsedEntry = struct {
    meta: WrittenEntry,
    raw: []u8,
};

pub fn freeParsedEntries(gpa: std.mem.Allocator, entries: []ParsedEntry) void {
    for (entries) |entry| gpa.free(entry.raw);
    gpa.free(entries);
}

pub fn writePack(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, entries: []const PlannedEntry) !WriteResult {
    if (entries.len == 0) return error.EmptyPack;

    const pack_name = try buildPackName(gpa, entries);
    errdefer gpa.free(pack_name);

    try root.createDirPath(io, "objects/pack");
    var pack_dir = try root.openDir(io, "objects/pack", .{});
    defer pack_dir.close(io);

    var encoded_entries: std.ArrayList(WrittenEntry) = .empty;
    defer encoded_entries.deinit(gpa);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, magic);
    try appendInt(&buf, gpa, u32, version);

    for (entries, 0..) |entry, i| {
        const entry_offset: u64 = @intCast(buf.items.len);
        const plan_base_index = entry.delta_base_index;
        const base_entry = if (plan_base_index) |base_index| blk: {
            if (base_index >= i) return error.InvalidPackPlan;
            break :blk encoded_entries.items[base_index];
        } else null;

        const payload = if (plan_base_index) |base_index|
            try encodeDelta(gpa, entries[base_index].raw, entry.raw)
        else
            try gpa.dupe(u8, entry.raw);
        defer gpa.free(payload);

        const encoding: Encoding = if (plan_base_index != null) .delta else .full;
        const crc32 = std.hash.Crc32.hash(entry.raw);
        try appendEntryHeader(&buf, gpa, .{
            .hash = entry.hash,
            .kind = entry.kind,
            .offset = entry_offset,
            .packed_len = payload.len,
            .unpacked_len = entry.raw.len,
            .encoding = encoding,
            .base_offset = if (base_entry) |base| base.offset else null,
            .base_hash = if (base_entry) |base| base.hash else null,
            .depth = if (base_entry != null) 1 else 0,
            .crc32 = crc32,
        });
        try buf.appendSlice(gpa, payload);
        try encoded_entries.append(gpa, .{
            .hash = entry.hash,
            .kind = entry.kind,
            .offset = entry_offset,
            .packed_len = payload.len,
            .unpacked_len = entry.raw.len,
            .encoding = encoding,
            .base_offset = if (base_entry) |base| base.offset else null,
            .base_hash = if (base_entry) |base| base.hash else null,
            .depth = if (base_entry != null) 1 else 0,
            .crc32 = crc32,
        });
    }

    var af = try pack_dir.createFileAtomic(io, pack_name, .{ .replace = false });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, buf.items);
    const linked = try fs_mod.linkDurable(io, &af);

    return .{
        .pack_name = pack_name,
        .entries = try encoded_entries.toOwnedSlice(gpa),
        .file_size = buf.items.len,
        .already_exists = !linked,
    };
}

pub fn readObject(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, pack_name: []const u8, entry_offset: u64) ![]u8 {
    const entries = try readPackEntries(io, root, gpa, pack_name);
    defer freeParsedEntries(gpa, entries);

    for (entries) |entry| {
        if (entry.meta.offset != entry_offset) continue;
        return try gpa.dupe(u8, entry.raw);
    }
    return error.ObjectNotFound;
}

pub fn readObjectByHash(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, target: Hash) !?ReadResult {
    const pack_files = try listPackFiles(io, root, gpa);
    defer freePackFiles(gpa, pack_files);

    for (pack_files) |pack_name| {
        const entries = try readPackEntries(io, root, gpa, pack_name);
        defer freeParsedEntries(gpa, entries);

        for (entries) |entry| {
            if (!entry.meta.hash.eql(target)) continue;
            return .{
                .pack_name = try gpa.dupe(u8, pack_name),
                .entry = entry.meta,
                .raw = try gpa.dupe(u8, entry.raw),
            };
        }
    }
    return null;
}

pub fn readPackEntries(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, pack_name: []const u8) ![]ParsedEntry {
    const pack_path = try std.fmt.allocPrint(gpa, "objects/pack/{s}", .{pack_name});
    defer gpa.free(pack_path);
    const data = try root.readFileAlloc(io, pack_path, gpa, .unlimited);
    defer gpa.free(data);

    if (data.len < fixed_header_len) return error.InvalidPackFile;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidPackFile;
    if (readInt(u32, data[magic.len .. magic.len + 4]) != version) return error.UnsupportedPackVersion;

    var entries: std.ArrayList(ParsedEntry) = .empty;
    errdefer {
        for (entries.items) |entry| gpa.free(entry.raw);
        entries.deinit(gpa);
    }

    var offset: usize = fixed_header_len;
    while (offset < data.len) {
        if (data.len - offset < entry_header_len) return error.InvalidPackFile;
        const entry_start = offset;
        var header = parseEntryHeader(data[offset .. offset + entry_header_len]) catch return error.InvalidPackFile;
        header.offset = @intCast(entry_start);
        offset += entry_header_len;

        const payload_len: usize = @intCast(header.packed_len);
        if (payload_len > data.len - offset) return error.InvalidPackFile;
        const payload = data[offset .. offset + payload_len];
        offset += payload_len;

        const base_entry = if (header.base_offset) |base_offset|
            findParsedEntry(entries.items, base_offset)
        else
            null;

        const raw = switch (header.encoding) {
            .full => try gpa.dupe(u8, payload),
            .delta => blk: {
                const base = base_entry orelse return error.InvalidPackFile;
                break :blk try applyDelta(gpa, base.raw, payload, @intCast(header.unpacked_len));
            },
        };
        errdefer gpa.free(raw);

        if (std.hash.Crc32.hash(raw) != header.crc32) return error.PackCrcMismatch;
        if (!Hash.ofBytes(raw).eql(header.hash)) return error.PackHashMismatch;

        try entries.append(gpa, .{
            .meta = .{
                .hash = header.hash,
                .kind = header.kind,
                .offset = header.offset,
                .packed_len = header.packed_len,
                .unpacked_len = header.unpacked_len,
                .encoding = header.encoding,
                .base_offset = header.base_offset,
                .base_hash = if (base_entry) |base| base.meta.hash else null,
                .depth = header.depth,
                .crc32 = header.crc32,
            },
            .raw = raw,
        });
    }

    return try entries.toOwnedSlice(gpa);
}

pub fn lookupPrefix(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, prefix: []const u8) !PrefixMatches {
    var matches: PrefixMatches = .{};
    const pack_files = try listPackFiles(io, root, gpa);
    defer freePackFiles(gpa, pack_files);

    for (pack_files) |pack_name| {
        const entries = try readPackEntries(io, root, gpa, pack_name);
        defer freeParsedEntries(gpa, entries);

        for (entries) |entry| {
            if (!entry.meta.hash.hasPrefix(prefix)) continue;
            if (matches.count < matches.hashes.len) {
                matches.hashes[matches.count] = entry.meta.hash;
            }
            matches.count += 1;
            if (matches.count > matches.hashes.len) return matches;
        }
    }
    return matches;
}

pub fn countEntries(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator) !usize {
    var count: usize = 0;
    const pack_files = try listPackFiles(io, root, gpa);
    defer freePackFiles(gpa, pack_files);

    for (pack_files) |pack_name| {
        const entries = try readPackEntries(io, root, gpa, pack_name);
        defer freeParsedEntries(gpa, entries);
        count += entries.len;
    }
    return count;
}

pub fn listPackFiles(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator) ![]const []u8 {
    var pack_dir = root.openDir(io, "objects/pack", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return try gpa.alloc([]u8, 0),
        else => return err,
    };
    defer pack_dir.close(io);

    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |name| gpa.free(name);
        files.deinit(gpa);
    }

    var iter = pack_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
        try files.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, files.items, {}, lessThanString);
    return try files.toOwnedSlice(gpa);
}

pub fn freePackFiles(gpa: std.mem.Allocator, pack_files: []const []u8) void {
    for (pack_files) |name| gpa.free(name);
    gpa.free(pack_files);
}

pub fn encodeDelta(gpa: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    const prefix_len = commonPrefixLen(base, target);
    const suffix_len = commonSuffixLen(base[prefix_len..], target[prefix_len..]);
    const replacement = target[prefix_len .. target.len - suffix_len];

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try appendInt(&buf, gpa, u64, prefix_len);
    try appendInt(&buf, gpa, u64, suffix_len);
    try appendInt(&buf, gpa, u64, replacement.len);
    try buf.appendSlice(gpa, replacement);
    return try buf.toOwnedSlice(gpa);
}

pub fn applyDelta(gpa: std.mem.Allocator, base: []const u8, payload: []const u8, expected_len: usize) ![]u8 {
    if (payload.len < 24) return error.InvalidPackDelta;
    const prefix_len: usize = @intCast(readInt(u64, payload[0..8]));
    const suffix_len: usize = @intCast(readInt(u64, payload[8..16]));
    const replacement_len: usize = @intCast(readInt(u64, payload[16..24]));
    if (prefix_len > base.len or suffix_len > base.len or prefix_len + suffix_len > base.len) return error.InvalidPackDelta;
    if (payload.len != 24 + replacement_len) return error.InvalidPackDelta;
    if (prefix_len + replacement_len + suffix_len != expected_len) return error.InvalidPackDelta;

    var out = try gpa.alloc(u8, expected_len);
    @memcpy(out[0..prefix_len], base[0..prefix_len]);
    @memcpy(out[prefix_len .. prefix_len + replacement_len], payload[24..]);
    @memcpy(out[prefix_len + replacement_len ..], base[base.len - suffix_len ..]);
    return out;
}

fn buildPackName(gpa: std.mem.Allocator, entries: []const PlannedEntry) ![]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    for (entries) |entry| {
        hasher.update(&entry.hash.bytes);
        hasher.update(&[_]u8{@intFromEnum(entry.kind)});
        if (entry.delta_base_index) |base_index| {
            hasher.update(&entries[base_index].hash.bytes);
        } else {
            hasher.update(&[_]u8{0});
        }
    }
    var digest: [hash_mod.digest_len]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "{s}.pack", .{hex});
}

fn appendEntryHeader(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, entry: WrittenEntry) !void {
    try buf.appendSlice(gpa, &entry.hash.bytes);
    try buf.append(gpa, @intFromEnum(entry.kind));
    try buf.append(gpa, @intFromEnum(entry.encoding));
    try appendInt(buf, gpa, u16, entry.depth);
    try appendInt(buf, gpa, u64, entry.unpacked_len);
    try appendInt(buf, gpa, u64, entry.packed_len);
    try appendInt(buf, gpa, u64, entry.base_offset orelse no_base_offset);
    try appendInt(buf, gpa, u32, entry.crc32);
    try appendInt(buf, gpa, u32, 0);
}

const ParsedHeader = struct {
    hash: Hash,
    kind: EntryKind,
    encoding: Encoding,
    depth: u16,
    unpacked_len: u64,
    packed_len: u64,
    base_offset: ?u64,
    crc32: u32,
    offset: u64,
};

fn parseEntryHeader(raw: []const u8) !ParsedHeader {
    if (raw.len != entry_header_len) return error.InvalidPackFile;
    var hash_bytes: [hash_mod.digest_len]u8 = undefined;
    @memcpy(&hash_bytes, raw[0..hash_mod.digest_len]);

    const kind: EntryKind = switch (raw[32]) {
        1 => .blob,
        2 => .tree,
        3 => .step,
        4 => .blame,
        else => return error.InvalidPackFile,
    };
    const encoding: Encoding = switch (raw[33]) {
        1 => .full,
        2 => .delta,
        else => return error.InvalidPackFile,
    };
    const depth = readInt(u16, raw[34..36]);
    const unpacked_len = readInt(u64, raw[36..44]);
    const packed_len = readInt(u64, raw[44..52]);
    const base_offset_raw = readInt(u64, raw[52..60]);
    const crc32 = readInt(u32, raw[60..64]);

    return .{
        .hash = .{ .bytes = hash_bytes },
        .kind = kind,
        .encoding = encoding,
        .depth = depth,
        .unpacked_len = unpacked_len,
        .packed_len = packed_len,
        .base_offset = if (base_offset_raw == no_base_offset) null else base_offset_raw,
        .crc32 = crc32,
        .offset = 0,
    };
}

fn findParsedEntry(entries: []const ParsedEntry, wanted_offset: u64) ?ParsedEntry {
    for (entries) |entry| {
        if (entry.meta.offset == wanted_offset) return entry;
    }
    return null;
}

fn appendInt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) !void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &tmp, value, .little);
    try buf.appendSlice(gpa, &tmp);
}

fn readInt(comptime T: type, raw: []const u8) T {
    return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const upper = @min(a.len, b.len);
    var i: usize = 0;
    while (i < upper and a[i] == b[i]) : (i += 1) {}
    return i;
}

fn commonSuffixLen(a: []const u8, b: []const u8) usize {
    const upper = @min(a.len, b.len);
    var i: usize = 0;
    while (i < upper and a[a.len - 1 - i] == b[b.len - 1 - i]) : (i += 1) {}
    return i;
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "delta round-trips" {
    const base = "line one\nline two\nline three\n";
    const target = "line one\nline changed\nline three\n";
    const payload = try encodeDelta(std.testing.allocator, base, target);
    defer std.testing.allocator.free(payload);

    const rebuilt = try applyDelta(std.testing.allocator, base, payload, target.len);
    defer std.testing.allocator.free(rebuilt);

    try std.testing.expectEqualStrings(target, rebuilt);
}

test "pack write and read round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const base = "hello world";
    const target = "hello there";
    const base_hash = Hash.ofBytes(base);
    const target_hash = Hash.ofBytes(target);

    var result = try writePack(io, tmp.dir, std.testing.allocator, &.{
        .{ .hash = base_hash, .kind = .blob, .raw = base },
        .{ .hash = target_hash, .kind = .blob, .raw = target, .delta_base_index = 0 },
    });
    defer result.deinit(std.testing.allocator);

    const base_back = try readObject(io, tmp.dir, std.testing.allocator, result.pack_name, result.entries[0].offset);
    defer std.testing.allocator.free(base_back);
    try std.testing.expectEqualStrings(base, base_back);

    const target_back = try readObject(io, tmp.dir, std.testing.allocator, result.pack_name, result.entries[1].offset);
    defer std.testing.allocator.free(target_back);
    try std.testing.expectEqualStrings(target, target_back);
}
