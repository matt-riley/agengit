const std = @import("std");
const output_mod = @import("output.zig");
const status = @import("status.zig");
const store_mod = @import("../store/store.zig");

pub const Target = struct {
    origin: []const u8,
    session_id: []const u8,

    pub fn deinit(self: Target, gpa: std.mem.Allocator) void {
        gpa.free(self.origin);
        gpa.free(self.session_id);
    }
};

pub fn resolveExisting(
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    command_name: []const u8,
    arg: ?[]const u8,
) !Target {
    if (arg == null) {
        const sess = try store.index.mostRecentSession(gpa) orelse {
            try status.writeDiagnostic(stdout, format, command_name, .{
                .code = "session_not_found",
                .message = "No sessions recorded yet.",
                .hint = "Record some activity first or pass an explicit session id.",
            });
            try stdout.flush();
            std.process.exit(1);
        };
        if (sess.head_hash) |hh| gpa.free(hh);
        return .{
            .origin = sess.origin,
            .session_id = sess.session_id,
        };
    }
    const value = arg.?;

    const sessions = try store.index.listSessions(gpa);
    defer store_mod.freeSessionRows(gpa, sessions);

    if (std.mem.indexOfScalar(u8, value, '/')) |sep| {
        const origin = value[0..sep];
        const session_id = value[sep + 1 ..];
        for (sessions) |session| {
            if (std.mem.eql(u8, session.origin, origin) and std.mem.eql(u8, session.session_id, session_id)) {
                return .{
                    .origin = try gpa.dupe(u8, origin),
                    .session_id = try gpa.dupe(u8, session_id),
                };
            }
        }
        try writeSessionNotFound(stdout, format, command_name, value);
        std.process.exit(1);
    }

    var match_count: usize = 0;
    var matched: ?Target = null;
    var candidates: std.ArrayList([]const u8) = .empty;
    defer {
        for (candidates.items) |candidate| gpa.free(candidate);
        candidates.deinit(gpa);
        if (matched) |target| target.deinit(gpa);
    }

    for (sessions) |session| {
        if (!std.mem.eql(u8, session.session_id, value)) continue;
        match_count += 1;
        try candidates.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ session.origin, session.session_id }));
        if (matched == null) {
            matched = .{
                .origin = try gpa.dupe(u8, session.origin),
                .session_id = try gpa.dupe(u8, session.session_id),
            };
        }
    }

    if (match_count == 0) {
        try writeSessionNotFound(stdout, format, command_name, value);
        std.process.exit(1);
    }
    if (match_count > 1) {
        try status.writeDiagnostic(stdout, format, command_name, .{
            .code = "ambiguous_session_id",
            .message = "Session id is ambiguous.",
            .hint = "Pass <origin>/<session-id> to disambiguate.",
            .path = value,
            .candidates = candidates.items,
        });
        try stdout.flush();
        std.process.exit(1);
    }

    const resolved = matched.?;
    matched = null;
    return resolved;
}

fn writeSessionNotFound(
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    command_name: []const u8,
    arg: []const u8,
) !void {
    try status.writeDiagnostic(stdout, format, command_name, .{
        .code = "session_not_found",
        .message = "Session not found.",
        .hint = "Pass <origin>/<session-id> or run `agit sessions`.",
        .path = arg,
    });
    try stdout.flush();
}
