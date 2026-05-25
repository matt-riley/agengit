const std = @import("std");

pub const digest_len: usize = 32;
pub const hex_len: usize = 64;

/// A 32-byte BLAKE3 content digest.
pub const Hash = struct {
    bytes: [digest_len]u8,

    /// Compute the BLAKE3 digest of `data`.
    pub fn ofBytes(data: []const u8) Hash {
        var h = std.crypto.hash.Blake3.init(.{});
        h.update(data);
        var out: [digest_len]u8 = undefined;
        h.final(&out);
        return .{ .bytes = out };
    }

    /// Parse a 64-character lowercase hex string into a Hash.
    pub fn fromHex(hex: []const u8) error{InvalidHash}!Hash {
        if (hex.len != hex_len) return error.InvalidHash;
        var bytes: [digest_len]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidHash;
        return .{ .bytes = bytes };
    }

    /// Returns a 64-character lowercase hex string for this hash.
    pub fn toHex(self: Hash) [hex_len]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    /// Returns true if this hash's hex representation starts with `prefix`.
    pub fn hasPrefix(self: Hash, prefix: []const u8) bool {
        if (prefix.len == 0) return true;
        if (prefix.len > hex_len) return false;
        const hex = self.toHex();
        return std.ascii.eqlIgnoreCase(hex[0..prefix.len], prefix);
    }

    pub fn eql(a: Hash, b: Hash) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

test "hash round-trip via hex" {
    const h = Hash.ofBytes("hello world");
    const hex = h.toHex();
    const parsed = try Hash.fromHex(&hex);
    try std.testing.expect(h.eql(parsed));
}

test "hash fromHex rejects wrong length" {
    try std.testing.expectError(error.InvalidHash, Hash.fromHex("abc"));
}

test "hash hasPrefix" {
    const h = Hash.ofBytes("test data");
    const hex = h.toHex();
    try std.testing.expect(h.hasPrefix(hex[0..8]));
    try std.testing.expect(!h.hasPrefix("0000000000000000"));
}

test "hash two distinct inputs produce distinct hashes" {
    const h1 = Hash.ofBytes("hello");
    const h2 = Hash.ofBytes("world");
    try std.testing.expect(!h1.eql(h2));
}
