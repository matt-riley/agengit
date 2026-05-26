const std = @import("std");
const harness = @import("support/harness.zig");

test "object_prefix_resolution/cat reports ambiguous candidates" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try seedAmbiguousObjects(&sandbox);

    var result = try sandbox.run(&.{ "cat", "aa" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Hash prefix is ambiguous.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "aa00000000000000000000000000000000000000000000000000000000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "aa11111111111111111111111111111111111111111111111111111111111111") != null);
}

test "object_prefix_resolution/show json includes ambiguous candidates" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try seedAmbiguousObjects(&sandbox);

    var result = try sandbox.run(&.{ "show", "--json", "aa" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.exit_code != 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.stdout, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const diagnostic = parsed.value.object.get("data").?.object.get("diagnostic").?.object;
    try std.testing.expectEqualStrings("ambiguous_hash_prefix", diagnostic.get("code").?.string);
    const candidates = diagnostic.get("candidates").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("aa00000000000000000000000000000000000000000000000000000000000000", candidates[0].string);
    try std.testing.expectEqualStrings("aa11111111111111111111111111111111111111111111111111111111111111", candidates[1].string);
}

fn seedAmbiguousObjects(sandbox: *harness.Sandbox) !void {
    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile(".agit/objects/aa/00000000000000000000000000000000000000000000000000000000000000", "alpha");
    try sandbox.writeRepoFile(".agit/objects/aa/11111111111111111111111111111111111111111111111111111111111111", "beta");
}
