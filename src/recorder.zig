const std = @import("std");
const config_mod = @import("store/config.zig");
const store_mod = @import("store/store.zig");
const object = @import("store/object.zig");
const redact_mod = @import("privacy/redact.zig");
const fs_mod = @import("util/fs.zig");
const file_lock_mod = @import("util/file_lock.zig");
const file_limits_mod = @import("util/file_limits.zig");
const git_mod = @import("util/git.zig");
const outcome_mod = @import("store/outcome.zig");

pub const Hash = store_mod.Hash;
pub const Ignorer = store_mod.Ignorer;
pub const Cause = object.Cause;
pub const StepMessage = object.StepMessage;
pub const StepToolCall = object.StepToolCall;

pub const HookFailureLogEntry = struct {
    ts: i64 = 0,
    level: []const u8 = "error",
    agent: ?[]const u8 = null,
    context: []const u8 = "",
    event: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    error_kind: []const u8 = "unknown",
    error_msg: []const u8 = "",
    payload_size: ?usize = null,
    payload_snippet: ?[]const u8 = null,
    parse_path: ?[]const u8 = null,
    parse_offset: ?usize = null,
    parse_line: ?usize = null,
    parse_column: ?usize = null,
    code: []const u8 = "hook_error",
    message: []const u8 = "hook failed",
    event_name: ?[]const u8 = null,
    field: ?[]const u8 = null,
    payload_bytes: ?usize = null,
    max_payload_bytes: ?usize = null,
    staging_key: ?[]const u8 = null,
    quarantine_path: ?[]const u8 = null,
};

pub const HookFailureDetails = HookFailureLogEntry;

pub fn logHookFailureFromCwd(
    io: std.Io,
    gpa: std.mem.Allocator,
    context: []const u8,
    err: anyerror,
    details: HookFailureDetails,
) void {
    var rec = Recorder.open(io, std.Io.Dir.cwd(), gpa) catch return;
    defer rec.deinit(io);
    rec.logHookFailure(io, context, err, details);
}

pub fn logHookFailureFromDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: std.Io.Dir,
    context: []const u8,
    err: anyerror,
    details: HookFailureDetails,
) void {
    var rec = Recorder.open(io, cwd, gpa) catch return;
    defer rec.deinit(io);
    rec.logHookFailure(io, context, err, details);
}

/// Metadata identifying a coding session.
pub const SessionMeta = struct {
    origin: []const u8,
    session_id: []const u8,
};

/// A user-role message to append to the staging file.
pub const UserPrompt = struct {
    content: []const u8,
};

/// A tool invocation to append to the staging file.
pub const ToolUse = struct {
    tool_name: []const u8,
    args: []const u8,
    result: ?[]const u8,
};

/// An assistant response, used when finalizing the turn.
pub const AssistantResponse = struct {
    content: []const u8,
};

/// The staged state for a single agent turn, persisted as JSON.
const TurnState = struct {
    messages: []const StepMessage = &.{},
    tool_calls: []const StepToolCall = &.{},
    causes: []const Cause = &.{},
    model: ?[]const u8 = null,
};

/// Compute a collision-safe staging key for (origin, session_id, turn_id).
///
/// Uses length-prefixed BLAKE3 to prevent field-separator injection collisions.
fn stagingKey(origin: []const u8, session_id: []const u8, turn_id: []const u8) [64]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var len_buf: [8]u8 = undefined;

    std.mem.writeInt(u64, &len_buf, origin.len, .little);
    hasher.update(&len_buf);
    hasher.update(origin);

    std.mem.writeInt(u64, &len_buf, session_id.len, .little);
    hasher.update(&len_buf);
    hasher.update(session_id);

    std.mem.writeInt(u64, &len_buf, turn_id.len, .little);
    hasher.update(&len_buf);
    hasher.update(turn_id);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Walk up from `start` until a directory containing `.agit/` is found.
/// Returns an owned `std.Io.Dir` for that repository root.
pub fn findStoreRoot(io: std.Io, start: std.Io.Dir) !std.Io.Dir {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Open "." so we own the handle and can safely close it.
    var current = try start.openDir(io, ".", .{});

    while (true) {
        const has_agit = blk: {
            var d = current.openDir(io, ".agit", .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => break :blk false,
                else => |e| {
                    current.close(io);
                    return e;
                },
            };
            d.close(io);
            break :blk true;
        };
        if (has_agit) return current;

        const parent = current.openDir(io, "..", .{}) catch |e| {
            current.close(io);
            return e;
        };

        const n1 = current.realPath(io, &path_buf) catch |e| {
            current.close(io);
            parent.close(io);
            return e;
        };
        const n2 = parent.realPath(io, &parent_buf) catch |e| {
            current.close(io);
            parent.close(io);
            return e;
        };

        if (std.mem.eql(u8, path_buf[0..n1], parent_buf[0..n2])) {
            // Reached the filesystem root without finding .agit/.
            current.close(io);
            parent.close(io);
            return error.StoreNotFound;
        }

        current.close(io);
        current = parent;
    }
}

/// A single append-only event stored as one JSONL line in the staging file.
///
/// The staging file is newline-delimited JSON: each hook call appends one
/// self-contained event line. On finalize the file is replayed line-by-line
/// to rebuild the `TurnState` in arrival order, instead of re-reading and
/// re-writing the whole document on every hook call.
const StagingEvent = struct {
    op: []const u8,
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    args: ?[]const u8 = null,
    result: ?[]const u8 = null,
    model: ?[]const u8 = null,
    cause: ?Cause = null,
};

/// Parse staging file data into a `TurnState`.
///
/// The new format is newline-delimited JSON (one `StagingEvent` per line).
/// An append that crashed mid-write leaves a trailing partial line; that
/// final line is skipped on parse failure when at least one prior event was
/// already read (truncation tolerance — strictly more robust than the old
/// full-document parse, which lost the whole turn on any truncation).
///
/// For in-flight files written by the prior read-modify-write format (a
/// single full JSON `TurnState` document, which has no `op` field and so
/// fails to parse as a `StagingEvent`), this falls back to a full-document
/// parse so an upgrade does not abandon a turn mid-flight.
///
/// Returns null for empty/whitespace-only data (an empty `TurnState`).
/// Returns an error if the data is neither valid JSONL nor a parseable
/// full document, so the caller can quarantine it.
fn parseStagingData(
    gpa: std.mem.Allocator,
    data: []const u8,
) !?std.json.Parsed(TurnState) {
    if (std.mem.trim(u8, data, " \t\r\n").len == 0) return null;

    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
    // `arena_released` is set whenever ownership of `arena_ptr` is transferred
    // away (to a `Parsed` on success, or freed before the legacy fallback).
    var arena_released = false;
    defer if (!arena_released) {
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
    };
    const arena = arena_ptr.allocator();

    var msgs: std.ArrayList(StepMessage) = .empty;
    var tcs: std.ArrayList(StepToolCall) = .empty;
    var causes: std.ArrayList(Cause) = .empty;
    var model: ?[]const u8 = null;

    // Collect non-empty line slices (views into `data`) so we can tell which
    // is last. Turn event counts are small; the whole point of the rewrite is
    // one O(lines) pass instead of N full rewrites.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        try lines.append(gpa, trimmed);
    }
    if (lines.items.len == 0) return null;

    var jsonl_ok = true;
    var saw_event = false;
    for (lines.items, 0..) |line, i| {
        var ev = std.json.parseFromSlice(StagingEvent, gpa, line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            const is_last = (i == lines.items.len - 1);
            // Truncation tolerance: a partial trailing line is skippable only
            // when we already have at least one complete event line (regardless
            // of op). Otherwise the file is garbage or an old-format single
            // document — fall back to the full-document parse below.
            if (is_last and saw_event) break;
            jsonl_ok = false;
            break;
        };
        defer ev.deinit();
        saw_event = true;

        const op = ev.value.op;
        if (std.mem.eql(u8, op, "message")) {
            if (ev.value.role) |r| {
                try msgs.append(arena, .{
                    .role = try arena.dupe(u8, r),
                    .content = try arena.dupe(u8, ev.value.content orelse ""),
                });
            }
        } else if (std.mem.eql(u8, op, "tool_call")) {
            try tcs.append(arena, .{
                .tool_name = try arena.dupe(u8, ev.value.tool_name orelse ""),
                .args = try arena.dupe(u8, ev.value.args orelse ""),
                .result = if (ev.value.result) |r| try arena.dupe(u8, r) else null,
            });
        } else if (std.mem.eql(u8, op, "model")) {
            if (ev.value.model) |m| model = try arena.dupe(u8, m);
        } else if (std.mem.eql(u8, op, "cause")) {
            if (ev.value.cause) |c| {
                try causes.append(arena, .{
                    .kind = try arena.dupe(u8, c.kind),
                    .ref = try arena.dupe(u8, c.ref),
                });
            }
        }
        // Unknown ops are ignored (forward-compat for new event kinds).
    }

    if (!jsonl_ok) {
        // Fall back to the legacy single-document TurnState format. Release
        // this arena first so the deferred cleanup does not double-free.
        arena_ptr.deinit();
        gpa.destroy(arena_ptr);
        arena_released = true;
        return try std.json.parseFromSlice(TurnState, gpa, data, .{ .allocate = .alloc_always });
    }

    const turn: TurnState = .{
        .messages = try arena.dupe(StepMessage, msgs.items),
        .tool_calls = try arena.dupe(StepToolCall, tcs.items),
        .causes = try arena.dupe(Cause, causes.items),
        .model = model,
    };
    // Transfer ownership of the arena to the returned `Parsed`.
    arena_released = true;
    return .{ .arena = arena_ptr, .value = turn };
}

/// Read and parse a `TurnState` from a JSON staging file.
/// Returns null if the file is absent or empty.
fn readStagingFile(
    io: std.Io,
    agit_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    path: []const u8,
) !?std.json.Parsed(TurnState) {
    const data = agit_dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(data);
    return parseStagingData(gpa, data);
}

/// The Phase 4 recorder: bridges the agent hook adapters (Phase 5) with the
/// object store (Phase 2) and snapshotter (Phase 3).
///
/// Each agent turn flows through three hook calls:
///   1. `recordUserPrompt`   — appended to a JSON staging file
///   2. `recordToolUse`      — appended to the same staging file (zero or more times)
///   3. `recordAssistantAndFinalize` — consumes the staging file, takes a
///       workspace snapshot, writes a Step object, and advances the session HEAD ref.
pub const RecorderOptions = struct {
    max_finalize_retries: u32 = 5,
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    store: store_mod.Store,
    repo_dir: std.Io.Dir,
    ignorer: Ignorer,
    privacy_config: config_mod.Loaded,
    max_finalize_retries: u32,

    /// Open a Recorder anchored at the nearest repository root.
    ///
    /// Walks up from `cwd` to find a directory containing `.agit/`, then
    /// opens the Store and loads `.agitignore` patterns.  Returns
    /// `error.StoreNotFound` if the filesystem root is reached first.
    pub fn open(io: std.Io, cwd: std.Io.Dir, gpa: std.mem.Allocator) !Recorder {
        return openWithOptions(io, cwd, gpa, .{});
    }

    pub fn openWithOptions(
        io: std.Io,
        cwd: std.Io.Dir,
        gpa: std.mem.Allocator,
        options: RecorderOptions,
    ) !Recorder {
        var repo_dir = try findStoreRoot(io, cwd);
        errdefer repo_dir.close(io);

        var s = try store_mod.Store.open(io, repo_dir, gpa);
        errdefer s.deinit(io);

        // Non-fatal: fall back to defaults if .agitignore is absent or unreadable.
        const ignorer = Ignorer.fromDir(io, repo_dir, gpa) catch Ignorer.initDefault(gpa);
        const privacy_config = config_mod.loadOrDefaultFromStore(io, s.root, gpa) catch config_mod.Loaded.failClosedCapture();

        return .{
            .gpa = gpa,
            .store = s,
            .repo_dir = repo_dir,
            .ignorer = ignorer,
            .privacy_config = privacy_config,
            .max_finalize_retries = @max(@as(u32, 1), options.max_finalize_retries),
        };
    }

    pub fn deinit(self: *Recorder, io: std.Io) void {
        self.ignorer.deinit();
        self.privacy_config.deinit();
        self.store.deinit(io);
        self.repo_dir.close(io);
        self.* = undefined;
    }

    pub fn originEnabled(self: *const Recorder, origin: []const u8) bool {
        return self.privacy_config.value.privacy.originEnabled(origin);
    }

    /// Upsert a session record in the index (no-op if already present).
    pub fn upsertSession(self: *Recorder, meta: SessionMeta) !void {
        try self.store.index.upsertSession(meta.origin, meta.session_id, null);
    }

    pub fn recordSessionModel(self: *Recorder, meta: SessionMeta, model: []const u8) !void {
        if (model.len == 0) return;
        const key = try modelMetaKey(self.gpa, meta.origin, meta.session_id);
        defer self.gpa.free(key);
        try self.store.index.metaSet(key, model);
    }

    pub fn recordTurnModel(
        self: *Recorder,
        io: std.Io,
        meta: SessionMeta,
        turn_id: []const u8,
        model: []const u8,
    ) !void {
        if (model.len == 0) return;
        const key = stagingKey(meta.origin, meta.session_id, turn_id);
        try self.setStagingModel(io, &key, model);
    }

    /// Append a user prompt to the turn's staging file.
    pub fn recordUserPrompt(
        self: *Recorder,
        io: std.Io,
        meta: SessionMeta,
        turn_id: []const u8,
        prompt: UserPrompt,
    ) !void {
        const key = stagingKey(meta.origin, meta.session_id, turn_id);
        const content = try self.captureText(self.privacy_config.value.privacy.capture.prompts, "prompt", prompt.content);
        defer self.gpa.free(content);
        try self.appendMessage(io, &key, .{ .role = "user", .content = content });
    }

    /// Append a tool invocation to the turn's staging file.
    pub fn recordToolUse(
        self: *Recorder,
        io: std.Io,
        meta: SessionMeta,
        turn_id: []const u8,
        tool: ToolUse,
    ) !void {
        const key = stagingKey(meta.origin, meta.session_id, turn_id);
        const args = try self.captureText(self.privacy_config.value.privacy.capture.tool_args, "tool arguments", tool.args);
        defer self.gpa.free(args);
        const result = if (tool.result) |value| blk: {
            const captured = try self.captureText(self.privacy_config.value.privacy.capture.tool_results, "tool result", value);
            break :blk captured;
        } else null;
        defer if (result) |value| self.gpa.free(value);
        try self.appendToolCall(io, &key, .{
            .tool_name = tool.tool_name,
            .args = args,
            .result = result,
        });
    }

    /// Consume the staging file, snapshot the workspace, write the Step object,
    /// advance the session HEAD ref, and index the messages/tool_calls.
    ///
    /// **Idempotent**: if a step with the same (origin, session_id, turn_id) is
    /// already committed (e.g. after a crash between CAS and index insert), this
    /// call re-inserts the message/tool_call rows without creating a duplicate.
    ///
    /// Returns `error.CasConflict` if `max_finalize_retries` consecutive concurrent writers
    /// prevent the CAS from landing — this is expected to be vanishingly rare in
    /// sequential hook models.
    pub fn recordAssistantAndFinalize(
        self: *Recorder,
        io: std.Io,
        meta: SessionMeta,
        turn_id: []const u8,
        response: AssistantResponse,
        causes: []const Cause,
    ) !void {
        const key = stagingKey(meta.origin, meta.session_id, turn_id);

        var staging = try self.consumeStaging(io, &key);
        defer if (staging) |*s| s.deinit();

        const staging_val: TurnState = if (staging) |s| s.value else .{};
        const session_model = if (staging_val.model == null) try self.readSessionModel(meta) else null;
        defer if (session_model) |value| self.gpa.free(value);
        const model = staging_val.model orelse session_model;

        // Build the full message list: prior staged messages + the assistant response.
        var msgs: std.ArrayList(StepMessage) = .empty;
        defer msgs.deinit(self.gpa);
        try msgs.appendSlice(self.gpa, staging_val.messages);
        const assistant = try self.captureText(self.privacy_config.value.privacy.capture.assistant, "assistant message", response.content);
        defer self.gpa.free(assistant);
        try msgs.append(self.gpa, .{ .role = "assistant", .content = assistant });

        // Merge causes from staging and the caller.
        var all_causes: std.ArrayList(Cause) = .empty;
        defer all_causes.deinit(self.gpa);
        try all_causes.appendSlice(self.gpa, staging_val.causes);
        try all_causes.appendSlice(self.gpa, causes);

        // Fast-path idempotency optimization via the index cache. The authoritative
        // deduplication guard remains commitFinalizedStep() returning .duplicate_turn.
        // If the index is stale and misses a committed turn, CAS still resolves it.
        if (try self.store.index.queryStepHash(meta.origin, meta.session_id, turn_id)) |existing_hex| {
            for (msgs.items, 0..) |msg, i| {
                try self.store.index.insertMessage(&existing_hex, @intCast(i), msg.role, msg.content);
            }
            for (staging_val.tool_calls, 0..) |tc, i| {
                try self.store.index.insertToolCall(&existing_hex, @intCast(i), tc.tool_name, tc.args, tc.result);
            }
            return;
        }

        // Hold the gc maintenance lock across snapshot/object writes and ref advance
        // so gc cannot prune deduplicated objects between capture and finalize.
        var maintenance_lock = try file_lock_mod.LockFile.acquire(io, self.store.root, "gc.lock", .{});
        defer maintenance_lock.release(io);

        // Decide up front whether incremental blame is safe this turn. If a prior
        // finalize failed to record blame (flag set) or could not be read, skip
        // incremental blame and leave the store stale until `agit reindex`.
        const do_incremental_blame = !(self.store.blameNeedsReindex() catch true);

        // Take a workspace snapshot — this is the same tree regardless of CAS retries.
        const tree_hash = try self.store.snapshot(
            io,
            self.repo_dir,
            self.gpa,
            &self.ignorer,
            .{
                .capture_level = self.privacy_config.value.privacy.capture.snapshots,
                .custom_literals = self.privacy_config.value.privacy.custom_literals,
            },
        );
        var tree_hex = tree_hash.toHex();

        // Strictly increasing step timestamps give blame a canonical global order
        // that `agit reindex` can reproduce. If the monotonic counter cannot be
        // read, fall back to wall-clock time but disable incremental blame so we
        // never record a non-monotonic timestamp into the blame chain.
        var timestamp_monotonic = true;
        const timestamp = self.store.monotonicTimestamp(std.Io.Timestamp.now(io, .real).toMilliseconds()) catch blk: {
            timestamp_monotonic = false;
            break :blk std.Io.Timestamp.now(io, .real).toMilliseconds();
        };
        var git_context = git_mod.captureContext(io, self.gpa, self.repo_dir) catch git_mod.Context{};
        defer git_context.deinit(self.gpa);
        const outcome = outcome_mod.derive(staging_val.tool_calls);

        var expected_parent = try self.store.readRef(io, self.gpa, meta.origin, meta.session_id);
        var attempt: u32 = 0;
        while (attempt < self.max_finalize_retries) : (attempt += 1) {
            const result = try self.store.commitFinalizedStep(io, self.gpa, .{
                .origin = meta.origin,
                .session_id = meta.session_id,
                .turn_id = turn_id,
                .tree_hash = tree_hex[0..],
                .timestamp = timestamp,
                .causes = all_causes.items,
                .messages = msgs.items,
                .tool_calls = staging_val.tool_calls,
                .outcome = outcome.label(),
                .model = model,
                .expected_parent = expected_parent,
                .retry_delta = @intCast(attempt),
                .git_commit = git_context.commit,
                .git_branch = git_context.branch,
                .git_dirty = git_context.dirty,
            });

            switch (result) {
                .committed => |step_hash| {
                    // Persist the advanced monotonic counter for the next
                    // finalize. Incremental blame is only safe if the timestamp
                    // was monotonic AND durably advanced; otherwise flag a
                    // reindex and skip so the chain never goes non-monotonic.
                    const timestamp_persisted = blk: {
                        self.store.advanceBlameTimestamp(timestamp) catch break :blk false;
                        break :blk true;
                    };
                    if (do_incremental_blame and timestamp_monotonic and timestamp_persisted) {
                        self.recordBlameForStep(io, step_hash, meta, tree_hex[0..], timestamp);
                    } else {
                        self.store.setBlameNeedsReindex(true) catch {};
                    }
                    return;
                },
                .parent_moved => |next_parent| {
                    expected_parent = next_parent;
                    continue;
                },
                .duplicate_turn => |existing_hex| {
                    for (msgs.items, 0..) |msg, i| {
                        try self.store.index.insertMessage(&existing_hex, @intCast(i), msg.role, msg.content);
                    }
                    for (staging_val.tool_calls, 0..) |tc, i| {
                        try self.store.index.insertToolCall(&existing_hex, @intCast(i), tc.tool_name, tc.args, tc.result);
                    }
                    return;
                },
            }
        }
        return error.CasConflict;
    }

    /// Record incremental blame for a just-committed step. Crash-safe and
    /// fail-open: the blame index is durably marked as needing a reindex BEFORE
    /// any blame is written, and the flag is cleared only after the rows commit
    /// successfully. A crash (or error) between commit and completion therefore
    /// leaves the flag set, so subsequent finalizes skip incremental blame
    /// (staying stale, never wrong) until `agit reindex` rebuilds and clears it.
    fn recordBlameForStep(
        self: *Recorder,
        io: std.Io,
        step_hash: Hash,
        meta: SessionMeta,
        tree_hex: []const u8,
        timestamp: i64,
    ) void {
        self.store.setBlameNeedsReindex(true) catch |err| {
            self.logHookFailure(io, "blame", err, .{ .session_id = meta.session_id });
            return;
        };
        const step_hex = step_hash.toHex();
        self.store.recordStepBlame(io, self.gpa, .{
            .step_hash = step_hex[0..],
            .tree_hash = tree_hex,
            .session_origin = meta.origin,
            .session_id = meta.session_id,
            .timestamp = timestamp,
            .max_file_bytes = file_limits_mod.effectiveMaxFileBytes(16 * 1024 * 1024),
        }) catch |err| {
            // Leave the reindex flag set so blame is rebuilt later.
            self.logHookFailure(io, "blame", err, .{ .session_id = meta.session_id });
            return;
        };
        self.store.setBlameNeedsReindex(false) catch {};
    }

    /// Write a structured error entry to `log/hook-error.log` inside `.agit/`.
    ///
    /// All I/O errors during logging are silently swallowed — this must never
    /// propagate errors back to the hook process.
    pub fn logError(self: *Recorder, io: std.Io, context: []const u8, err: anyerror) void {
        self.logHookFailure(io, context, err, .{});
    }

    pub fn logHookFailure(
        self: *Recorder,
        io: std.Io,
        context: []const u8,
        err: anyerror,
        details: HookFailureDetails,
    ) void {
        var entry = details;
        entry.ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
        entry.level = "error";
        entry.agent = details.agent orelse context;
        entry.context = context;
        entry.error_kind = @as([]const u8, @errorName(err));
        entry.event = details.event_name;
        entry.error_msg = details.message;
        entry.payload_size = details.payload_bytes;

        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();

        std.json.Stringify.value(entry, .{}, &aw.writer) catch return;
        const entry_json = aw.writer.buffered();

        self.appendHookLog(io, entry_json) catch return;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /// Append a single JSONL event line to the staging file, under the staging
    /// lock. No read, no parse, no full rewrite — one small positional append.
    /// Durability mirrors `appendHookLog`: fsync the file content, then sync the
    /// `tmp/` directory (which no-ops when `AGIT_FSYNC` is disabled).
    fn appendStagingEvent(self: *Recorder, io: std.Io, key: *const [64]u8, event: StagingEvent) !void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        try std.json.Stringify.value(event, .{ .emit_null_optional_fields = false }, &aw.writer);
        const line = aw.writer.buffered();

        // "tmp/" (4) + key (64) + ".json" (5) = 73 chars
        var path_buf: [73]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key.*}) catch unreachable;
        // "tmp/" (4) + key (64) + ".json.lock" (10) = 78 chars
        var lock_buf: [78]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_buf, "tmp/{s}.json.lock", .{key.*}) catch unreachable;

        var lock = try file_lock_mod.LockFile.acquire(io, self.store.root, lock_path, .{});
        defer lock.release(io);

        var file = try self.store.root.createFile(io, path, .{ .read = true, .truncate = false });
        defer file.close(io);

        const offset = try file.length(io);
        try file.writePositionalAll(io, line, offset);
        try file.writePositionalAll(io, "\n", offset + line.len);
        try file.sync(io);
        var tmp_dir = try self.store.root.openDir(io, "tmp", .{});
        defer tmp_dir.close(io);
        try fs_mod.syncDir(io, tmp_dir);
    }

    /// Append a message to the staging file, under the staging lock.
    fn appendMessage(self: *Recorder, io: std.Io, key: *const [64]u8, msg: StepMessage) !void {
        try self.appendStagingEvent(io, key, .{
            .op = "message",
            .role = msg.role,
            .content = msg.content,
        });
    }

    /// Append a tool call to the staging file, under the staging lock.
    fn appendToolCall(self: *Recorder, io: std.Io, key: *const [64]u8, tc: StepToolCall) !void {
        try self.appendStagingEvent(io, key, .{
            .op = "tool_call",
            .tool_name = tc.tool_name,
            .args = tc.args,
            .result = tc.result,
        });
    }

    fn setStagingModel(self: *Recorder, io: std.Io, key: *const [64]u8, model: []const u8) !void {
        try self.appendStagingEvent(io, key, .{
            .op = "model",
            .model = model,
        });
    }

    /// Consume (read and delete) the staging file for the given key.
    ///
    /// The staging file is deleted **under the lock** to prevent a concurrent
    /// writer from appending after finalize reads the state.
    fn consumeStaging(
        self: *Recorder,
        io: std.Io,
        key: *const [64]u8,
    ) !?std.json.Parsed(TurnState) {
        var path_buf: [73]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key.*}) catch unreachable;
        var lock_buf: [78]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_buf, "tmp/{s}.json.lock", .{key.*}) catch unreachable;

        var lock = try file_lock_mod.LockFile.acquire(io, self.store.root, lock_path, .{});
        defer lock.release(io);

        const data = self.store.root.readFileAlloc(io, path, self.gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => {
                var quarantine_buf: [128]u8 = undefined;
                const quarantine_path = self.quarantineStagingByRename(io, key, path, &quarantine_buf) catch null;
                self.logHookFailure(io, "recorder-finalize", err, .{
                    .code = "corrupt_staging",
                    .message = "failed to read staging file during finalize",
                    .staging_key = key[0..],
                    .quarantine_path = quarantine_path,
                });
                return error.CorruptStaging;
            },
        };
        defer self.gpa.free(data);

        const parsed = parseStagingData(self.gpa, data) catch |err| {
            var quarantine_buf: [128]u8 = undefined;
            const quarantine_path = try self.quarantineStagingData(io, key, path, data, &quarantine_buf);
            self.logHookFailure(io, "recorder-finalize", err, .{
                .code = "corrupt_staging",
                .message = "failed to parse staging file during finalize",
                .staging_key = key[0..],
                .quarantine_path = quarantine_path,
            });
            return error.CorruptStaging;
        };

        // Delete while still holding the lock, after the staging data is known-good.
        self.store.root.deleteFile(io, path) catch {};
        return parsed;
    }

    fn appendHookLog(self: *Recorder, io: std.Io, entry_json: []const u8) !void {
        var lock = try file_lock_mod.LockFile.acquire(io, self.store.root, "log/hook-error.log.lock", .{});
        defer lock.release(io);

        var file = try self.store.root.createFile(io, "log/hook-error.log", .{
            .read = true,
            .truncate = false,
        });
        defer file.close(io);

        const offset = try file.length(io);
        try file.writePositionalAll(io, entry_json, offset);
        try file.writePositionalAll(io, "\n", offset + entry_json.len);
        try file.sync(io);
        var log_dir = try self.store.root.openDir(io, "log", .{});
        defer log_dir.close(io);
        try fs_mod.syncDir(io, log_dir);
    }

    fn captureText(
        self: *const Recorder,
        level: config_mod.CaptureLevel,
        label: []const u8,
        text: []const u8,
    ) ![]u8 {
        return switch (level) {
            .full => try self.gpa.dupe(u8, text),
            .redacted => try redact_mod.redactAlloc(self.gpa, text, .{
                .custom_literals = self.privacy_config.value.privacy.custom_literals,
            }),
            .metadata_only => try std.fmt.allocPrint(self.gpa, "[[agit {s} metadata-only: {d} bytes]]", .{
                label,
                text.len,
            }),
            .disabled => try std.fmt.allocPrint(self.gpa, "[[agit {s} capture disabled]]", .{label}),
        };
    }

    fn readSessionModel(self: *Recorder, meta: SessionMeta) !?[]const u8 {
        const key = try modelMetaKey(self.gpa, meta.origin, meta.session_id);
        defer self.gpa.free(key);
        return self.store.index.metaGet(self.gpa, key);
    }

    fn quarantineStagingPath(
        self: *Recorder,
        io: std.Io,
        key: *const [64]u8,
        path_buf: []u8,
    ) ![]const u8 {
        try self.store.root.createDirPath(io, "log/corrupt-staging");
        const timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds();
        return std.fmt.bufPrint(path_buf, "log/corrupt-staging/{d}-{s}.json", .{ timestamp, key.* });
    }

    fn quarantineStagingData(
        self: *Recorder,
        io: std.Io,
        key: *const [64]u8,
        staging_path: []const u8,
        data: []const u8,
        path_buf: []u8,
    ) ![]const u8 {
        const quarantine_path = try self.quarantineStagingPath(io, key, path_buf);
        var af = try self.store.root.createFileAtomic(io, quarantine_path, .{
            .replace = false,
            .make_path = false,
        });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, data);
        if (!try fs_mod.linkDurable(io, &af)) return error.PathAlreadyExists;
        try self.store.root.deleteFile(io, staging_path);
        return quarantine_path;
    }

    fn quarantineStagingByRename(
        self: *Recorder,
        io: std.Io,
        key: *const [64]u8,
        staging_path: []const u8,
        path_buf: []u8,
    ) ![]const u8 {
        const quarantine_path = try self.quarantineStagingPath(io, key, path_buf);
        try fs_mod.renameDurable(io, self.store.root, staging_path, self.store.root, quarantine_path);
        return quarantine_path;
    }
};

fn modelMetaKey(gpa: std.mem.Allocator, origin: []const u8, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "session::{x}:{x}::model", .{ origin, session_id });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn makeRecorder(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) !Recorder {
    try dir.createDirPath(io, ".agit");
    const s = try store_mod.Store.open(io, dir, gpa);
    const ignorer = Ignorer.initDefault(gpa);
    return .{
        .gpa = gpa,
        .store = s,
        .repo_dir = try dir.openDir(io, ".", .{}),
        .ignorer = ignorer,
        .privacy_config = config_mod.Loaded.default(),
        .max_finalize_retries = 5,
    };
}

test "stagingKey: distinct inputs produce distinct keys" {
    const k1 = stagingKey("origin", "session", "turn-1");
    const k2 = stagingKey("origin", "session", "turn-2");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "stagingKey: length-prefix prevents separator collision" {
    // "a:b" split as origin="a", session_id="b" vs origin="a:b", session_id=""
    const k1 = stagingKey("a", "b", "t");
    const k2 = stagingKey("a:b", "", "t");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "findStoreRoot: finds .agit in current dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".agit");

    var found = try findStoreRoot(io, tmp.dir);
    defer found.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try found.realPath(io, &path_buf);
    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ne = try tmp.dir.realPath(io, &expected_buf);
    try std.testing.expectEqualStrings(expected_buf[0..ne], path_buf[0..n]);
}

test "findStoreRoot: walks up to find .agit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".agit");
    try tmp.dir.createDirPath(io, "subdir/nested");

    var subdir = try tmp.dir.openDir(io, "subdir/nested", .{});
    defer subdir.close(io);

    var found = try findStoreRoot(io, subdir);
    defer found.close(io);

    // Should be the tmp.dir, not subdir/nested.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try found.realPath(io, &path_buf);
    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ne = try tmp.dir.realPath(io, &expected_buf);
    try std.testing.expectEqualStrings(expected_buf[0..ne], path_buf[0..n]);
}

test "findStoreRoot: returns StoreNotFound when no .agit present" {
    const io = std.testing.io;

    var tmp_root = try std.Io.Dir.cwd().openDir(io, "/tmp", .{});
    defer tmp_root.close(io);
    try std.testing.expectError(error.StoreNotFound, findStoreRoot(io, tmp_root));
}

test "recordUserPrompt: staging file contains user message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "test", .session_id = "s1" };
    try rec.recordUserPrompt(io, meta, "t1", .{ .content = "hello" });

    const key = stagingKey("test", "s1", "t1");
    var path_buf: [73]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;
    var parsed = try readStagingFile(io, rec.store.root, gpa, path);
    defer if (parsed) |*p| p.deinit();

    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.?.value.messages.len);
    try std.testing.expectEqualStrings("user", parsed.?.value.messages[0].role);
    try std.testing.expectEqualStrings("hello", parsed.?.value.messages[0].content);
}

test "recordToolUse: appends to existing staging state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "test", .session_id = "s1" };
    try rec.recordUserPrompt(io, meta, "t1", .{ .content = "prompt" });
    try rec.recordToolUse(io, meta, "t1", .{ .tool_name = "bash", .args = "ls", .result = "ok" });

    const key = stagingKey("test", "s1", "t1");
    var path_buf: [73]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;
    var parsed = try readStagingFile(io, rec.store.root, gpa, path);
    defer if (parsed) |*p| p.deinit();

    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.?.value.messages.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.?.value.tool_calls.len);
    try std.testing.expectEqualStrings("bash", parsed.?.value.tool_calls[0].tool_name);
}

test "recordAssistantAndFinalize: full round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "gh/u/r", .session_id = "sess-1" };
    try rec.recordUserPrompt(io, meta, "t1", .{ .content = "user says hi" });
    try rec.recordToolUse(io, meta, "t1", .{ .tool_name = "grep", .args = "foo", .result = "bar" });
    try rec.recordAssistantAndFinalize(io, meta, "t1", .{ .content = "assistant reply" }, &.{});

    // HEAD ref must be set.
    const head = try rec.store.readRef(io, gpa, meta.origin, meta.session_id);
    try std.testing.expect(head != null);

    // Step object must include messages and tool_calls.
    var step_parsed = try rec.store.readStep(io, gpa, head.?);
    defer step_parsed.deinit();
    const step = step_parsed.value;

    try std.testing.expectEqual(@as(usize, 2), step.messages.len);
    try std.testing.expectEqualStrings("user", step.messages[0].role);
    try std.testing.expectEqualStrings("assistant", step.messages[1].role);
    try std.testing.expectEqual(@as(usize, 1), step.tool_calls.len);
    try std.testing.expectEqualStrings("grep", step.tool_calls[0].tool_name);

    // Index should have message and tool_call rows.
    const hex = head.?.toHex();
    const msg_row = try rec.store.index.db.row(
        "select role from messages where step_hash=? and seq=0",
        .{hex[0..]},
    );
    try std.testing.expect(msg_row != null);
    defer msg_row.?.deinit();
    try std.testing.expectEqualStrings("user", msg_row.?.get([]const u8, 0));

    // Staging file must be deleted after finalize.
    const key = stagingKey(meta.origin, meta.session_id, "t1");
    var path_buf: [73]u8 = undefined;
    const staging_path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;
    const exists = blk: {
        _ = rec.store.root.statFile(io, staging_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!exists);
}

test "recordAssistantAndFinalize: empty turn (no staging file)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "gh/u/r", .session_id = "sess-2" };
    // Finalize without any prior recordUserPrompt/recordToolUse.
    try rec.recordAssistantAndFinalize(io, meta, "t1", .{ .content = "solo reply" }, &.{});

    const head = try rec.store.readRef(io, gpa, meta.origin, meta.session_id);
    try std.testing.expect(head != null);

    var step_parsed = try rec.store.readStep(io, gpa, head.?);
    defer step_parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), step_parsed.value.messages.len);
    try std.testing.expectEqualStrings("assistant", step_parsed.value.messages[0].role);
}

test "recordAssistantAndFinalize: idempotent on duplicate turn_id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "gh/u/r", .session_id = "sess-3" };
    try rec.recordAssistantAndFinalize(io, meta, "t1", .{ .content = "first" }, &.{});

    const head1 = try rec.store.readRef(io, gpa, meta.origin, meta.session_id);
    try std.testing.expect(head1 != null);

    // Calling finalize again with the same turn_id must not error or create a duplicate.
    try rec.recordAssistantAndFinalize(io, meta, "t1", .{ .content = "retry" }, &.{});

    // HEAD must still point to the same step.
    const head2 = try rec.store.readRef(io, gpa, meta.origin, meta.session_id);
    try std.testing.expect(head2 != null);
    try std.testing.expect(head1.?.eql(head2.?));
}

test "recordAssistantAndFinalize: corrupt staging file is quarantined and logged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "gh/u/r", .session_id = "sess-4" };
    const key = stagingKey(meta.origin, meta.session_id, "t1");
    var path_buf: [73]u8 = undefined;
    const staging_path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;

    // Write garbage to the staging file.
    var f = try rec.store.root.createFile(io, staging_path, .{});
    try f.writeStreamingAll(io, "not-valid-json!!!");
    f.close(io);

    try std.testing.expectError(
        error.CorruptStaging,
        rec.recordAssistantAndFinalize(io, meta, "t1", .{ .content = "ok" }, &.{}),
    );

    const head = try rec.store.readRef(io, gpa, meta.origin, meta.session_id);
    try std.testing.expect(head == null);

    _ = rec.store.root.statFile(io, staging_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var quarantine_dir = try rec.store.root.openDir(io, "log/corrupt-staging", .{ .iterate = true });
    defer quarantine_dir.close(io);
    var it = quarantine_dir.iterate();
    const entry = (try it.next(io)) orelse return error.MissingQuarantineFile;
    try std.testing.expectEqualStrings(".json", entry.name[entry.name.len - 5 ..]);

    const log = try rec.store.root.readFileAlloc(io, "log/hook-error.log", gpa, .unlimited);
    defer gpa.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "corrupt_staging") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "log/corrupt-staging/") != null);
}

test "logError: writes a JSON line to hook-error.log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    rec.logError(io, "test-context", error.OutOfMemory);

    const log = try rec.store.root.readFileAlloc(io, "log/hook-error.log", gpa, .unlimited);
    defer gpa.free(log);

    try std.testing.expect(std.mem.indexOf(u8, log, "test-context") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "OutOfMemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "error") != null);
}

test "logError: appends to existing log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    rec.logError(io, "ctx-1", error.Unexpected);
    rec.logError(io, "ctx-2", error.OutOfMemory);

    const log = try rec.store.root.readFileAlloc(io, "log/hook-error.log", gpa, .unlimited);
    defer gpa.free(log);

    try std.testing.expect(std.mem.indexOf(u8, log, "ctx-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "ctx-2") != null);
}

test "logError: repeated writes preserve one line per failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    rec.logError(io, "ctx-1", error.Unexpected);
    rec.logError(io, "ctx-2", error.OutOfMemory);
    rec.logHookFailure(io, "ctx-3", error.InvalidFieldType, .{
        .code = "invalid_field_type",
        .message = "invalid field",
        .field = "session_id",
    });

    const log = try rec.store.root.readFileAlloc(io, "log/hook-error.log", gpa, .unlimited);
    defer gpa.free(log);

    var lines: usize = 0;
    for (log) |byte| {
        if (byte == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
    try std.testing.expect(std.mem.indexOf(u8, log, "invalid_field_type") != null);
}

test "append-only staging: append message/tool/model replay in arrival order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "test", .session_id = "s1" };

    // setStagingModel is reachable only via recordTurnModel (which gates empty).
    try rec.recordTurnModel(io, meta, "t1", "claude-opus");
    try rec.recordUserPrompt(io, meta, "t1", .{ .content = "hello" });
    try rec.recordToolUse(io, meta, "t1", .{ .tool_name = "bash", .args = "ls", .result = "ok" });
    try rec.recordToolUse(io, meta, "t1", .{ .tool_name = "grep", .args = "foo", .result = null });

    const key = stagingKey(meta.origin, meta.session_id, "t1");
    var path_buf: [73]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;
    var parsed = try readStagingFile(io, rec.store.root, gpa, path);
    defer if (parsed) |*pp| pp.deinit();

    try std.testing.expect(parsed != null);
    const st = parsed.?.value;
    try std.testing.expectEqual(@as(usize, 1), st.messages.len);
    try std.testing.expectEqualStrings("user", st.messages[0].role);
    try std.testing.expectEqualStrings("hello", st.messages[0].content);
    try std.testing.expectEqual(@as(usize, 2), st.tool_calls.len);
    try std.testing.expectEqualStrings("bash", st.tool_calls[0].tool_name);
    try std.testing.expectEqualStrings("grep", st.tool_calls[1].tool_name);
    try std.testing.expect(st.tool_calls[1].result == null);
    try std.testing.expectEqualStrings("claude-opus", st.model.?);
}

test "append-only staging: truncated final JSONL line is tolerated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "test", .session_id = "s1" };
    try rec.recordUserPrompt(io, meta, "t1", .{ .content = "first" });
    try rec.recordToolUse(io, meta, "t1", .{ .tool_name = "bash", .args = "ls", .result = "ok" });

    const key = stagingKey(meta.origin, meta.session_id, "t1");
    var path_buf: [73]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;

    // Append a partial (unterminated) final line to simulate a crash mid-write.
    var f = try rec.store.root.createFile(io, path, .{ .read = true, .truncate = false });
    const offset = try f.length(io);
    try f.writePositionalAll(io, "{\"op\":\"tool_call\",\"bad", offset);
    f.close(io);

    var parsed = try readStagingFile(io, rec.store.root, gpa, path);
    defer if (parsed) |*pp| pp.deinit();

    try std.testing.expect(parsed != null);
    const st = parsed.?.value;
    // The two complete events are recovered; the partial tail is skipped.
    try std.testing.expectEqual(@as(usize, 1), st.messages.len);
    try std.testing.expectEqualStrings("first", st.messages[0].content);
    try std.testing.expectEqual(@as(usize, 1), st.tool_calls.len);
    try std.testing.expectEqualStrings("bash", st.tool_calls[0].tool_name);
}

test "append-only staging: legacy single-document staging file is readable (dual-read)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "test", .session_id = "s1" };
    const key = stagingKey(meta.origin, meta.session_id, "t1");
    var path_buf: [73]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;

    // Write the OLD read-modify-write format: a single full TurnState document.
    const legacy =
        \\{"messages":[{"role":"user","content":"legacy"}],"tool_calls":[{"tool_name":"grep","args":"x","result":"y"}],"causes":[],"model":"legacy-model"}
    ;
    var f = try rec.store.root.createFile(io, path, .{});
    try f.writeStreamingAll(io, legacy);
    f.close(io);

    var parsed = try readStagingFile(io, rec.store.root, gpa, path);
    defer if (parsed) |*pp| pp.deinit();

    try std.testing.expect(parsed != null);
    const st = parsed.?.value;
    try std.testing.expectEqual(@as(usize, 1), st.messages.len);
    try std.testing.expectEqualStrings("legacy", st.messages[0].content);
    try std.testing.expectEqual(@as(usize, 1), st.tool_calls.len);
    try std.testing.expectEqualStrings("grep", st.tool_calls[0].tool_name);
    try std.testing.expectEqualStrings("legacy-model", st.model.?);
}

test "append-only staging: garbage-only file fails to parse (not silently skipped)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var rec = try makeRecorder(io, tmp.dir, gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "test", .session_id = "s1" };
    const key = stagingKey(meta.origin, meta.session_id, "t1");
    var path_buf: [73]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tmp/{s}.json", .{key}) catch unreachable;

    var f = try rec.store.root.createFile(io, path, .{});
    try f.writeStreamingAll(io, "{not-json");
    f.close(io);

    // A file with zero complete events is corrupt: dual-read falls back to the
    // full-document parse, which also fails -> error (not an empty TurnState).
    try std.testing.expectError(
        error.CorruptStaging,
        rec.recordAssistantAndFinalize(io, meta, "t1", .{ .content = "ok" }, &.{}),
    );
}
