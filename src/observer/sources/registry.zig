const std = @import("std");
const source_mod = @import("../Source.zig");
const jsonl = @import("jsonl.zig");

pub const all = [_]source_mod.Source{
    jsonl.source,
};

pub fn find(name: []const u8) ?source_mod.Source {
    for (all) |source| {
        if (std.mem.eql(u8, source.name, name)) return source;
    }
    return null;
}

test "registered observer sources declare load handlers" {
    for (all) |entry| {
        try std.testing.expect(entry.name.len > 0);
        try std.testing.expect(entry.summary.len > 0);
    }
}
