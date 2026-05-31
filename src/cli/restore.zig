const std = @import("std");
const config_mod = @import("../store/config.zig");
const fs_mod = @import("../util/fs.zig");
const path_safety = @import("../store/path_safety.zig");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");

pub const usage = specs.restore_usage;

const metadata_only_prefix = "[[agit snapshot metadata-only path=";

const RestoreOptions = struct {
    format: output_mod.Format = .human,
    hash_prefix: ?[]const u8 = null,
    all: bool = false,
    force: bool = false,
    dry_run: bool = false,
    filters: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *RestoreOptions, gpa: std.mem.Allocator) void {
        self.filters.deinit(gpa);
        self.* = undefined;
    }
};

const RestoreItem = struct {
    path: []const u8,
    status: []const u8,
    reason: ?[]const u8 = null,
    bytes: u64 = 0,
};

const RestoreCounts = struct {
    restored: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

const TargetStatus = enum {
    missing,
    file,
    symlink,
    directory,
    special,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    var options = parseOptions(gpa, iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        error.InvalidArgument => return,
        else => return err,
    };
    defer options.deinit(gpa);

    const prefix = options.hash_prefix orelse {
        if (options.format == .json) {
            try status.writeDiagnostic(&stdout, .json, usage.name, .{
                .code = "missing_hash",
                .message = "A step hash prefix is required.",
            });
        } else {
            try help_mod.renderUsage(&stdout, usage);
        }
        try stdout.flush();
        std.process.exit(1);
    };

    if (!options.all and options.filters.items.len == 0) {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "restore_scope_required",
            .message = "Restore requires --all or one or more paths after --.",
            .hint = "Use `agit restore <hash> -- path` or `agit restore --all <hash>`.",
        });
        if (options.format == .human) {
            try stdout.interface.writeAll("\n");
            try help_mod.renderUsage(&stdout, usage);
        }
        try stdout.flush();
        std.process.exit(1);
    }

    if (options.all and options.filters.items.len > 0) {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_restore_scope",
            .message = "Use either --all or path filters, not both.",
        });
        try stdout.flush();
        std.process.exit(1);
    }

    try validateRequestedFilters(&stdout, options);

    var repo_dir = openRepoRootOrExit(io, gpa, &stdout, options.format);
    defer repo_dir.close(io);

    var store = openStoreOrExit(io, repo_dir, gpa, &stdout, options.format);
    defer store.deinit(io);

    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_config",
            .message = "Failed to load .agit/config.json.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer loaded_config.deinit();
    const warning: ?[]const u8 = if (loaded_config.value.privacy.display.redacted_by_default)
        "restore writes raw captured bytes; display redaction is not applied"
    else
        null;

    const step_hash = resolveStepHash(io, gpa, &store, prefix, options.format, &stdout);
    const step_hex = step_hash.toHex();

    var parsed_step = store.readStep(io, gpa, step_hash) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "step_read_failed",
            .message = "Failed to read step object.",
            .hint = @errorName(err),
            .hash = step_hex[0..],
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer parsed_step.deinit();

    var tree = readTreeFromHex(io, gpa, &store, parsed_step.value.tree, options.format, &stdout);
    defer tree.deinit();

    var items: std.ArrayList(RestoreItem) = .empty;
    defer items.deinit(gpa);

    if (!try validateTreeEntries(&items, gpa, tree.value.entries)) {
        try writeSummary(&stdout, options, items.items, warning);
        try stdout.flush();
        std.process.exit(1);
    }

    const matched_filters = try gpa.alloc(bool, options.filters.items.len);
    defer gpa.free(matched_filters);
    @memset(matched_filters, false);

    for (tree.value.entries) |entry| {
        if (!options.all and !selectsEntry(options.filters.items, matched_filters, entry.path)) continue;
        try restoreEntry(io, gpa, &store, repo_dir, options, entry, &items);
    }

    for (options.filters.items, matched_filters) |filter, matched| {
        if (!matched) {
            try items.append(gpa, .{
                .path = filter,
                .status = "failed",
                .reason = "not_in_tree",
            });
        }
    }

    try writeSummary(&stdout, options, items.items, warning);
    try stdout.flush();
    const counts = countItems(items.items);
    if (counts.failed > 0) std.process.exit(1);
}

fn parseOptions(gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !RestoreOptions {
    var options = RestoreOptions{};
    errdefer options.deinit(gpa);

    var path_mode = false;
    while (iter.next()) |arg| {
        if (path_mode) {
            try options.filters.append(gpa, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            path_mode = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.all = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try invalidArgument(stdout, options.format, "Unknown option.");
            return error.InvalidArgument;
        } else if (options.hash_prefix == null) {
            options.hash_prefix = arg;
        } else {
            try invalidArgument(stdout, options.format, "Unexpected argument.");
            return error.InvalidArgument;
        }
    }

    if (path_mode and options.filters.items.len == 0) {
        try invalidArgument(stdout, options.format, "`--` must be followed by at least one captured path.");
        return error.InvalidArgument;
    }
    return options;
}

fn invalidArgument(stdout: *std.Io.File.Writer, format: output_mod.Format, message: []const u8) !void {
    try status.writeDiagnostic(stdout, format, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    if (format == .human) {
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(stdout, usage);
    }
    try stdout.flush();
}

fn validateRequestedFilters(stdout: *std.Io.File.Writer, options: RestoreOptions) !void {
    for (options.filters.items) |filter| {
        path_safety.validateWorkspaceRelativePath(filter) catch |err| {
            try status.writeDiagnostic(stdout, options.format, usage.name, .{
                .code = "unsafe_path",
                .message = "Requested restore path is not a safe workspace-relative path.",
                .hint = @errorName(err),
                .path = filter,
            });
            try stdout.flush();
            std.process.exit(1);
        };
    }
}

fn openRepoRootOrExit(io: std.Io, gpa: std.mem.Allocator, stdout: *std.Io.File.Writer, format: output_mod.Format) std.Io.Dir {
    _ = gpa;
    return store_mod.Store.findRoot(io, std.Io.Dir.cwd()) catch |err| {
        switch (err) {
            error.StoreNotFound => status.writeDiagnostic(stdout, format, usage.name, .{
                .code = "store_not_found",
                .message = "Not an agit repository.",
                .hint = "Run `agit init` from the repository root to start recording.",
                .path = ".",
            }) catch {},
            else => status.writeDiagnostic(stdout, format, usage.name, .{
                .code = "store_open_failed",
                .message = "Failed to find agit repository root.",
                .hint = @errorName(err),
                .path = ".",
            }) catch {},
        }
        stdout.flush() catch {};
        std.process.exit(1);
    };
}

fn openStoreOrExit(
    io: std.Io,
    repo_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
) store_mod.Store {
    return store_mod.Store.openExisting(io, repo_dir, gpa) catch |err| {
        status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "store_open_failed",
            .message = "Failed to open agit store.",
            .hint = @errorName(err),
            .path = ".agit",
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
}

fn resolveStepHash(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    prefix: []const u8,
    format: output_mod.Format,
    stdout: *std.Io.File.Writer,
) store_mod.Hash {
    const resolution = store.resolvePrefix(io, gpa, prefix) catch |err| {
        status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "object_lookup_failed",
            .message = "Failed to resolve object prefix.",
            .hint = @errorName(err),
            .hash = prefix,
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };

    return switch (resolution) {
        .not_found => {
            status.writeDiagnostic(stdout, format, usage.name, .{
                .code = "object_not_found",
                .message = "Object not found.",
                .hint = "Use a longer or different hash prefix.",
                .hash = prefix,
            }) catch {};
            stdout.flush() catch {};
            std.process.exit(1);
        },
        .ambiguous => |matches| {
            var candidate_hex: [2][64]u8 = .{ matches[0].toHex(), matches[1].toHex() };
            if (std.mem.lessThan(u8, candidate_hex[1][0..], candidate_hex[0][0..])) {
                std.mem.swap([64]u8, &candidate_hex[0], &candidate_hex[1]);
            }
            const candidates = [_][]const u8{ candidate_hex[0][0..], candidate_hex[1][0..] };
            status.writeDiagnostic(stdout, format, usage.name, .{
                .code = "ambiguous_hash_prefix",
                .message = "Hash prefix is ambiguous.",
                .hint = "Use a longer hash prefix.",
                .hash = prefix,
                .candidates = candidates[0..],
            }) catch {};
            stdout.flush() catch {};
            std.process.exit(1);
        },
        .unique => |resolved| resolved,
    };
}

fn readTreeFromHex(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    tree_hash_hex: []const u8,
    format: output_mod.Format,
    stdout: *std.Io.File.Writer,
) std.json.Parsed(store_mod.Tree) {
    const tree_hash = store_mod.Hash.fromHex(tree_hash_hex) catch {
        status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "invalid_tree_hash",
            .message = "Step tree hash is invalid.",
            .hash = tree_hash_hex,
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
    return store.readTree(io, gpa, tree_hash) catch |err| {
        status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "tree_read_failed",
            .message = "Failed to read step tree.",
            .hint = @errorName(err),
            .hash = tree_hash_hex,
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
}

fn validateTreeEntries(items: *std.ArrayList(RestoreItem), gpa: std.mem.Allocator, entries: []const store_mod.TreeEntry) !bool {
    var ok = true;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.mode, "file")) {
            ok = false;
            try items.append(gpa, .{
                .path = entry.path,
                .status = "failed",
                .reason = "unsupported_mode",
            });
            continue;
        }
        path_safety.validateWorkspaceRelativePath(entry.path) catch |err| {
            ok = false;
            try items.append(gpa, .{
                .path = entry.path,
                .status = "failed",
                .reason = @errorName(err),
            });
        };
    }
    return ok;
}

fn selectsEntry(filters: []const []const u8, matched_filters: []bool, path: []const u8) bool {
    var selected = false;
    for (filters, 0..) |filter, i| {
        if (std.mem.eql(u8, filter, path)) {
            matched_filters[i] = true;
            selected = true;
        }
    }
    return selected;
}

fn restoreEntry(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    repo_dir: std.Io.Dir,
    options: RestoreOptions,
    entry: store_mod.TreeEntry,
    items: *std.ArrayList(RestoreItem),
) !void {
    checkParentDirs(io, repo_dir, gpa, entry.path) catch |err| {
        try items.append(gpa, failedItem(entry.path, @errorName(err)));
        return;
    };

    const target_status = statTarget(io, repo_dir, entry.path) catch |err| {
        try items.append(gpa, failedItem(entry.path, @errorName(err)));
        return;
    };
    switch (target_status) {
        .directory => {
            try items.append(gpa, failedItem(entry.path, "is_directory"));
            return;
        },
        .special => {
            try items.append(gpa, failedItem(entry.path, "unsupported_target_type"));
            return;
        },
        .file, .symlink => if (!options.force) {
            try items.append(gpa, .{
                .path = entry.path,
                .status = "skipped",
                .reason = "exists",
            });
            return;
        },
        .missing => {},
    }

    const blob_hash = store_mod.Hash.fromHex(entry.blob) catch {
        try items.append(gpa, failedItem(entry.path, "invalid_blob_hash"));
        return;
    };
    const data = store.readBlob(io, gpa, blob_hash) catch |err| {
        try items.append(gpa, failedItem(entry.path, @errorName(err)));
        return;
    };
    defer gpa.free(data);

    if (std.mem.startsWith(u8, data, metadata_only_prefix)) {
        try items.append(gpa, failedItem(entry.path, "metadata_only_blob"));
        return;
    }

    if (options.dry_run) {
        try items.append(gpa, .{
            .path = entry.path,
            .status = "planned",
            .bytes = @intCast(data.len),
        });
        return;
    }

    writeWorkspaceFile(io, repo_dir, gpa, entry.path, data, options.force) catch |err| {
        try items.append(gpa, failedItem(entry.path, @errorName(err)));
        return;
    };
    try items.append(gpa, .{
        .path = entry.path,
        .status = "restored",
        .bytes = @intCast(data.len),
    });
}

fn failedItem(path: []const u8, reason: []const u8) RestoreItem {
    return .{
        .path = path,
        .status = "failed",
        .reason = reason,
    };
}

fn statTarget(io: std.Io, repo_dir: std.Io.Dir, path: []const u8) !TargetStatus {
    const stat = repo_dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotDir => return error.ParentNotDirectory,
        else => return err,
    };
    return switch (stat.kind) {
        .file => .file,
        .sym_link => .symlink,
        .directory => .directory,
        else => .special,
    };
}

fn checkParentDirs(io: std.Io, repo_dir: std.Io.Dir, gpa: std.mem.Allocator, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try walkParentComponents(io, repo_dir, gpa, path[0..sep], false);
    }
}

fn ensureParentDirs(io: std.Io, repo_dir: std.Io.Dir, gpa: std.mem.Allocator, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try walkParentComponents(io, repo_dir, gpa, path[0..sep], true);
    }
}

fn walkParentComponents(
    io: std.Io,
    repo_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    parent_path: []const u8,
    create_missing: bool,
) !void {
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);

    var segments = std.mem.splitScalar(u8, parent_path, '/');
    while (segments.next()) |segment| {
        if (current.items.len > 0) try current.append(gpa, '/');
        try current.appendSlice(gpa, segment);

        const stat = repo_dir.statFile(io, current.items, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (!create_missing) return;
                repo_dir.createDir(io, current.items, .default_dir) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    error.NotDir => return error.ParentNotDirectory,
                    else => return create_err,
                };
                const created_stat = repo_dir.statFile(io, current.items, .{ .follow_symlinks = false }) catch |stat_err| switch (stat_err) {
                    error.NotDir => return error.ParentNotDirectory,
                    else => return stat_err,
                };
                if (created_stat.kind != .directory) return error.ParentNotDirectory;
                continue;
            },
            error.NotDir => return error.ParentNotDirectory,
            else => return err,
        };
        if (stat.kind != .directory) return error.ParentNotDirectory;
    }
}

fn writeWorkspaceFile(
    io: std.Io,
    repo_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    force: bool,
) !void {
    try ensureParentDirs(io, repo_dir, gpa, path);
    var af = try repo_dir.createFileAtomic(io, path, .{ .replace = force, .make_path = false });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, data);
    if (force) {
        try fs_mod.atomicReplace(io, &af);
    } else if (!try fs_mod.linkDurable(io, &af)) {
        return error.TargetExists;
    }
}

fn countItems(items: []const RestoreItem) RestoreCounts {
    var counts = RestoreCounts{};
    for (items) |item| {
        if (std.mem.eql(u8, item.status, "failed")) {
            counts.failed += 1;
        } else if (std.mem.eql(u8, item.status, "skipped")) {
            counts.skipped += 1;
        } else {
            counts.restored += 1;
        }
    }
    return counts;
}

fn writeSummary(
    stdout: *std.Io.File.Writer,
    options: RestoreOptions,
    items: []const RestoreItem,
    warning: ?[]const u8,
) !void {
    const counts = countItems(items);
    switch (options.format) {
        .json => try output_mod.writeEnvelope(stdout, usage.name, .{
            .dry_run = options.dry_run,
            .counts = counts,
            .items = items,
            .warning = warning,
        }),
        .human => {
            if (warning) |message| {
                try stdout.interface.print("warning: {s}\n\n", .{message});
            }
            for (items) |item| {
                if (std.mem.eql(u8, item.status, "restored")) {
                    try stdout.interface.print("restored {s} ({d} bytes)\n", .{ item.path, item.bytes });
                } else if (std.mem.eql(u8, item.status, "planned")) {
                    try stdout.interface.print("would restore {s} ({d} bytes)\n", .{ item.path, item.bytes });
                } else if (std.mem.eql(u8, item.status, "skipped")) {
                    try stdout.interface.print("skipped {s}: {s}\n", .{ item.path, item.reason orelse "skipped" });
                } else {
                    try stdout.interface.print("failed {s}: {s}\n", .{ item.path, item.reason orelse "failed" });
                }
            }
            if (items.len > 0) try stdout.interface.writeAll("\n");
            if (options.dry_run) {
                try stdout.interface.print("Dry run summary: would restore {d}, skipped {d}, failed {d}.\n", .{
                    counts.restored,
                    counts.skipped,
                    counts.failed,
                });
            } else {
                try stdout.interface.print("Restore summary: restored {d}, skipped {d}, failed {d}.\n", .{
                    counts.restored,
                    counts.skipped,
                    counts.failed,
                });
            }
        },
    }
}

test "selectsEntry matches exact filters and records matches" {
    const filters = [_][]const u8{ "src/main.zig", "README.md" };
    var matched = [_]bool{ false, false };

    try std.testing.expect(selectsEntry(filters[0..], matched[0..], "src/main.zig"));
    try std.testing.expect(matched[0]);
    try std.testing.expect(!matched[1]);
    try std.testing.expect(!selectsEntry(filters[0..], matched[0..], "src/main.zig.bak"));
}

test "writeWorkspaceFile creates parents and refuses existing files without force" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeWorkspaceFile(io, tmp.dir, std.testing.allocator, "a/b.txt", "one\n", false);
    const got = try tmp.dir.readFileAlloc(io, "a/b.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("one\n", got);

    try std.testing.expectError(error.TargetExists, writeWorkspaceFile(io, tmp.dir, std.testing.allocator, "a/b.txt", "two\n", false));
    try writeWorkspaceFile(io, tmp.dir, std.testing.allocator, "a/b.txt", "two\n", true);
    const overwritten = try tmp.dir.readFileAlloc(io, "a/b.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(overwritten);
    try std.testing.expectEqualStrings("two\n", overwritten);
}
