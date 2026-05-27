const std = @import("std");

const config_mod = @import("config.zig");
const object_mod = @import("object.zig");
const ref_mod = @import("ref.zig");
const store_mod = @import("store.zig");

const payload_magic = "AGITRM01";
const payload_flag_encrypted: u8 = 0x01;

pub const PushResult = struct {
    uploaded_objects: usize = 0,
    skipped_objects: usize = 0,
    uploaded_refs: usize = 0,
    skipped_refs: usize = 0,
    encrypted: bool = false,
    first_conflict: ?RefConflict = null,

    pub fn deinit(self: *PushResult, gpa: std.mem.Allocator) void {
        if (self.first_conflict) |*conflict| conflict.deinit(gpa);
        self.* = undefined;
    }
};

pub const PullResult = struct {
    downloaded_objects: usize = 0,
    skipped_objects: usize = 0,
    created_refs: usize = 0,
    updated_refs: usize = 0,
    unchanged_refs: usize = 0,
    encrypted: bool = false,
    first_conflict: ?RefConflict = null,

    pub fn deinit(self: *PullResult, gpa: std.mem.Allocator) void {
        if (self.first_conflict) |*conflict| conflict.deinit(gpa);
        self.* = undefined;
    }
};

pub const RefConflict = struct {
    path: []u8,
    local_hash: [64]u8,
    remote_hash: [64]u8,

    pub fn deinit(self: *RefConflict, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.* = undefined;
    }
};

const LocalRef = struct {
    path: []u8,
    origin: []u8,
    session_id: []u8,
    hash: store_mod.Hash,
};

const RemoteRef = struct {
    path: []u8,
    origin: []u8,
    session_id: []u8,
    hash: store_mod.Hash,
};

const ResolvedRemote = struct {
    config: config_mod.RemoteConfig,
    endpoint_uri: std.Uri,
    access_key: []const u8,
    secret_key: []const u8,
    session_token: ?[]const u8,
    encryption_secret: ?[]const u8,
};

const S3Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,
    remote: ResolvedRemote,

    fn init(io: std.Io, gpa: std.mem.Allocator, remote: ResolvedRemote) S3Client {
        return .{
            .io = io,
            .gpa = gpa,
            .client = .{
                .allocator = gpa,
                .io = io,
            },
            .remote = remote,
        };
    }

    fn deinit(self: *S3Client) void {
        self.client.deinit();
        self.* = undefined;
    }

    fn headObject(self: *S3Client, key: []const u8) !bool {
        const canonical_uri = try canonicalUriAlloc(self.gpa, self.remote, key);
        defer self.gpa.free(canonical_uri);
        return self.requestHasObject(.HEAD, canonical_uri, "");
    }

    fn getObjectAlloc(self: *S3Client, key: []const u8) ![]u8 {
        const canonical_uri = try canonicalUriAlloc(self.gpa, self.remote, key);
        defer self.gpa.free(canonical_uri);
        return self.requestBodyAlloc(.GET, canonical_uri, "", null);
    }

    fn putObject(self: *S3Client, key: []const u8, payload: []const u8) !void {
        const canonical_uri = try canonicalUriAlloc(self.gpa, self.remote, key);
        defer self.gpa.free(canonical_uri);
        _ = try self.requestStatus(.PUT, canonical_uri, "", payload);
    }

    fn getRefAlloc(self: *S3Client, path: []const u8) !?store_mod.Hash {
        const key = try prefixedKeyAlloc(self.gpa, self.remote.config.prefix, path);
        defer self.gpa.free(key);

        const canonical_uri = try canonicalUriAlloc(self.gpa, self.remote, key);
        defer self.gpa.free(canonical_uri);

        const body = self.requestBodyAlloc(.GET, canonical_uri, "", null) catch |err| switch (err) {
            error.RemoteObjectNotFound => return null,
            else => return err,
        };
        defer self.gpa.free(body);

        const trimmed = std.mem.trim(u8, body, " \r\n");
        return try store_mod.Hash.fromHex(trimmed);
    }

    fn putRef(self: *S3Client, path: []const u8, hash: store_mod.Hash) !void {
        const key = try prefixedKeyAlloc(self.gpa, self.remote.config.prefix, path);
        defer self.gpa.free(key);

        const canonical_uri = try canonicalUriAlloc(self.gpa, self.remote, key);
        defer self.gpa.free(canonical_uri);

        const hex = hash.toHex();
        var content: [65]u8 = undefined;
        @memcpy(content[0..64], &hex);
        content[64] = '\n';
        _ = try self.requestStatus(.PUT, canonical_uri, "", content[0..]);
    }

    fn listRefsAlloc(self: *S3Client) ![]RemoteRef {
        var all = std.ArrayList(RemoteRef).empty;
        errdefer {
            freeRemoteRefs(self.gpa, all.items);
            all.deinit(self.gpa);
        }

        const ref_prefix = try prefixedKeyAlloc(self.gpa, self.remote.config.prefix, "refs/sessions/");
        defer self.gpa.free(ref_prefix);

        var continuation: ?[]u8 = null;
        defer if (continuation) |token| self.gpa.free(token);

        while (true) {
            const query = try listQueryAlloc(self.gpa, ref_prefix, continuation);
            defer self.gpa.free(query);

            const canonical_uri = try canonicalUriAlloc(self.gpa, self.remote, "");
            defer self.gpa.free(canonical_uri);

            const body = try self.requestBodyAlloc(.GET, canonical_uri, query, null);
            defer self.gpa.free(body);

            var page = try parseListRefsPage(self.gpa, body, self.remote.config.prefix);
            defer page.deinit(self.gpa);
            for (page.paths) |path| {
                const path_without_root = path["refs/sessions/".len..];
                const sep = std.mem.indexOfScalar(u8, path_without_root, '/') orelse continue;
                const origin = try ref_mod.decodePathComponentAlloc(self.gpa, path_without_root[0..sep]);
                errdefer self.gpa.free(origin);
                const session_id = try ref_mod.decodePathComponentAlloc(self.gpa, path_without_root[sep + 1 ..]);
                errdefer self.gpa.free(session_id);
                const hash = (try self.getRefAlloc(path)) orelse return error.InvalidRemoteResponse;
                try all.append(self.gpa, .{
                    .path = try self.gpa.dupe(u8, path),
                    .origin = origin,
                    .session_id = session_id,
                    .hash = hash,
                });
            }

            if (!page.truncated) break;
            if (continuation) |token| self.gpa.free(token);
            continuation = page.next_token orelse return error.InvalidRemoteResponse;
            page.next_token = null;
        }

        return all.toOwnedSlice(self.gpa);
    }

    fn requestHasObject(self: *S3Client, method: std.http.Method, canonical_uri: []const u8, canonical_query: []const u8) !bool {
        const status = self.requestStatus(method, canonical_uri, canonical_query, null) catch |err| switch (err) {
            error.RemoteObjectNotFound => return false,
            else => return err,
        };
        return status == .ok or status == .no_content;
    }

    fn requestBodyAlloc(
        self: *S3Client,
        method: std.http.Method,
        canonical_uri: []const u8,
        canonical_query: []const u8,
        payload: ?[]const u8,
    ) ![]u8 {
        var body_writer = std.Io.Writer.Allocating.init(self.gpa);
        errdefer body_writer.deinit();

        const status = try self.requestStatusInto(method, canonical_uri, canonical_query, payload, &body_writer.writer);
        switch (status) {
            .ok => {},
            else => return error.RemoteUnexpectedStatus,
        }

        var list = body_writer.toArrayList();
        return list.toOwnedSlice(self.gpa);
    }

    fn requestStatus(
        self: *S3Client,
        method: std.http.Method,
        canonical_uri: []const u8,
        canonical_query: []const u8,
        payload: ?[]const u8,
    ) !std.http.Status {
        return self.requestStatusInto(method, canonical_uri, canonical_query, payload, null);
    }

    fn requestStatusInto(
        self: *S3Client,
        method: std.http.Method,
        canonical_uri: []const u8,
        canonical_query: []const u8,
        payload: ?[]const u8,
        response_writer: ?*std.Io.Writer,
    ) !std.http.Status {
        const payload_bytes = payload orelse "";
        const payload_sha = sha256Hex(payload_bytes);
        const request_time = RequestTime.now(self.io);

        const host_header = try hostHeaderAlloc(self.gpa, self.remote.endpoint_uri);
        defer self.gpa.free(host_header);

        const signed_headers = if (self.remote.session_token != null)
            "host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
        else
            "host;x-amz-content-sha256;x-amz-date";

        const canonical_headers = if (self.remote.session_token) |token|
            try std.fmt.allocPrint(
                self.gpa,
                "host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\nx-amz-security-token:{s}\n",
                .{ host_header, &payload_sha, &request_time.amz_date, token },
            )
        else
            try std.fmt.allocPrint(
                self.gpa,
                "host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n",
                .{ host_header, &payload_sha, &request_time.amz_date },
            );
        defer self.gpa.free(canonical_headers);

        const canonical_request = try std.fmt.allocPrint(self.gpa, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
            @tagName(method),
            canonical_uri,
            canonical_query,
            canonical_headers,
            signed_headers,
            &payload_sha,
        });
        defer self.gpa.free(canonical_request);

        const canonical_request_sha = sha256Hex(canonical_request);
        const scope = try std.fmt.allocPrint(self.gpa, "{s}/{s}/s3/aws4_request", .{
            request_time.date_stamp[0..],
            self.remote.config.region,
        });
        defer self.gpa.free(scope);

        const string_to_sign = try std.fmt.allocPrint(self.gpa, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{
            request_time.amz_date[0..],
            scope,
            &canonical_request_sha,
        });
        defer self.gpa.free(string_to_sign);

        const authorization = try authorizationHeaderAlloc(
            self.gpa,
            self.remote,
            request_time.date_stamp[0..],
            scope,
            signed_headers,
            string_to_sign,
        );
        defer self.gpa.free(authorization);

        var extra_headers: [4]std.http.Header = undefined;
        var extra_len: usize = 0;
        extra_headers[extra_len] = .{ .name = "authorization", .value = authorization };
        extra_len += 1;
        extra_headers[extra_len] = .{ .name = "x-amz-content-sha256", .value = &payload_sha };
        extra_len += 1;
        extra_headers[extra_len] = .{ .name = "x-amz-date", .value = request_time.amz_date[0..] };
        extra_len += 1;
        if (self.remote.session_token) |token| {
            extra_headers[extra_len] = .{ .name = "x-amz-security-token", .value = token };
            extra_len += 1;
        }

        const url = try requestUrlAlloc(self.gpa, self.remote.config.endpoint, canonical_uri, canonical_query);
        defer self.gpa.free(url);

        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = "agit" },
            },
            .extra_headers = extra_headers[0..extra_len],
            .response_writer = response_writer,
        }) catch |err| switch (err) {
            error.HttpConnectionClosing => return error.RemoteTransportFailed,
            else => return err,
        };

        return switch (result.status) {
            .ok, .created, .no_content => result.status,
            .not_found => error.RemoteObjectNotFound,
            else => error.RemoteUnexpectedStatus,
        };
    }
};

const ListRefsPage = struct {
    paths: []const []u8,
    truncated: bool,
    next_token: ?[]u8 = null,

    fn deinit(self: *ListRefsPage, gpa: std.mem.Allocator) void {
        for (self.paths) |path| gpa.free(@constCast(path));
        if (self.paths.len > 0) gpa.free(self.paths);
        if (self.next_token) |token| gpa.free(token);
        self.* = undefined;
    }
};

const RequestTime = struct {
    amz_date: [16]u8,
    date_stamp: [8]u8,

    fn now(io: std.Io) RequestTime {
        const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const secs: u64 = @intCast(@max(0, @divTrunc(ms, 1000)));
        const es = std.time.epoch.EpochSeconds{ .secs = secs };
        const eday = es.getEpochDay();
        const yd = eday.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();

        var amz_date: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&amz_date, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        }) catch unreachable;

        var date_stamp: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&date_stamp, "{d:0>4}{d:0>2}{d:0>2}", .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
        }) catch unreachable;

        return .{
            .amz_date = amz_date,
            .date_stamp = date_stamp,
        };
    }
};

pub fn push(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    store: *store_mod.Store,
    remote_config: config_mod.RemoteConfig,
) !PushResult {
    const remote = try resolveRemote(environ, remote_config);
    var client = S3Client.init(io, gpa, remote);
    defer client.deinit();

    var result: PushResult = .{ .encrypted = remote.encryption_secret != null };
    errdefer result.deinit(gpa);

    const refs = try collectLocalRefs(io, gpa, store);
    defer freeLocalRefs(gpa, refs);

    var reachable = std.AutoHashMap([64]u8, void).init(gpa);
    defer reachable.deinit();
    for (refs) |local_ref| {
        try markStepChain(io, gpa, store, &reachable, local_ref.hash);
    }

    var iterator = reachable.keyIterator();
    while (iterator.next()) |hash_ptr| {
        const key = try objectKeyAlloc(gpa, remote_config.prefix, hash_ptr.*);
        defer gpa.free(key);

        if (try client.headObject(key)) {
            result.skipped_objects += 1;
            continue;
        }

        const hash = try store_mod.Hash.fromHex(hash_ptr);
        const plain = try store.readBlob(io, gpa, hash);
        defer gpa.free(plain);

        const encoded = try encodeRemoteObjectAlloc(gpa, hash_ptr.*, plain, remote.encryption_secret);
        defer gpa.free(encoded);

        try client.putObject(key, encoded);
        result.uploaded_objects += 1;
    }

    for (refs) |local_ref| {
        const remote_head = try client.getRefAlloc(local_ref.path);
        if (remote_head) |head| {
            if (head.eql(local_ref.hash)) {
                result.skipped_refs += 1;
                continue;
            }
            if (!try isAncestorInStore(io, gpa, store, head, local_ref.hash)) {
                result.first_conflict = .{
                    .path = try gpa.dupe(u8, local_ref.path),
                    .local_hash = local_ref.hash.toHex(),
                    .remote_hash = head.toHex(),
                };
                return result;
            }
        }
        try client.putRef(local_ref.path, local_ref.hash);
        result.uploaded_refs += 1;
    }

    return result;
}

pub fn pull(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    store: *store_mod.Store,
    remote_config: config_mod.RemoteConfig,
) !PullResult {
    const remote = try resolveRemote(environ, remote_config);
    var client = S3Client.init(io, gpa, remote);
    defer client.deinit();

    var result: PullResult = .{ .encrypted = remote.encryption_secret != null };
    errdefer result.deinit(gpa);

    const refs = try client.listRefsAlloc();
    defer freeRemoteRefs(gpa, refs);

    var seen = std.AutoHashMap([64]u8, void).init(gpa);
    defer seen.deinit();

    for (refs) |remote_ref| {
        try fetchReachableFromRemote(io, gpa, store, &client, remote_ref.hash, &seen, &result);

        const local_head = try ref_mod.readSessionRef(io, store.root, gpa, remote_ref.origin, remote_ref.session_id);
        if (local_head) |head| {
            if (head.eql(remote_ref.hash)) {
                result.unchanged_refs += 1;
                continue;
            }
            if (try isAncestorInStore(io, gpa, store, head, remote_ref.hash)) {
                try ref_mod.writeSessionRef(io, store.root, gpa, remote_ref.origin, remote_ref.session_id, remote_ref.hash);
                result.updated_refs += 1;
                continue;
            }
            if (try isAncestorInStore(io, gpa, store, remote_ref.hash, head)) {
                result.unchanged_refs += 1;
                continue;
            }

            result.first_conflict = .{
                .path = try gpa.dupe(u8, remote_ref.path),
                .local_hash = head.toHex(),
                .remote_hash = remote_ref.hash.toHex(),
            };
            return result;
        }

        try ref_mod.writeSessionRef(io, store.root, gpa, remote_ref.origin, remote_ref.session_id, remote_ref.hash);
        result.created_refs += 1;
    }

    return result;
}

fn resolveRemote(environ: std.process.Environ, config: config_mod.RemoteConfig) !ResolvedRemote {
    const endpoint_uri = try std.Uri.parse(config.endpoint);
    if (endpoint_uri.host == null) return error.InvalidRemoteEndpoint;
    if (!endpoint_uri.path.isEmpty()) {
        var path_buf: [256]u8 = undefined;
        const path = endpoint_uri.path.toRaw(&path_buf) catch return error.InvalidRemoteEndpoint;
        if (!std.mem.eql(u8, path, "/")) return error.InvalidRemoteEndpoint;
    }
    if (endpoint_uri.query != null or endpoint_uri.fragment != null) return error.InvalidRemoteEndpoint;

    const access_key = environ.getPosix(config.access_key_env) orelse return error.MissingRemoteCredential;
    const secret_key = environ.getPosix(config.secret_key_env) orelse return error.MissingRemoteCredential;
    const session_token = if (config.session_token_env) |name|
        (environ.getPosix(name) orelse return error.MissingRemoteCredential)
    else
        null;
    const encryption_secret = if (config.encryption_secret_env) |name|
        (environ.getPosix(name) orelse return error.MissingEncryptionSecret)
    else
        null;

    return .{
        .config = config,
        .endpoint_uri = endpoint_uri,
        .access_key = access_key,
        .secret_key = secret_key,
        .session_token = session_token,
        .encryption_secret = encryption_secret,
    };
}

fn collectLocalRefs(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store) ![]LocalRef {
    var refs_dir = store.root.openDir(io, "refs/sessions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer refs_dir.close(io);

    var walker = try refs_dir.walk(gpa);
    defer walker.deinit();

    var refs = std.ArrayList(LocalRef).empty;
    errdefer {
        freeLocalRefs(gpa, refs.items);
        refs.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".lock")) continue;

        const data = try refs_dir.readFileAlloc(io, entry.path, gpa, .unlimited);
        defer gpa.free(data);
        const hash = try store_mod.Hash.fromHex(std.mem.trim(u8, data, " \r\n"));

        const sep = std.mem.indexOfScalar(u8, entry.path, '/') orelse continue;
        const origin = try ref_mod.decodePathComponentAlloc(gpa, entry.path[0..sep]);
        errdefer gpa.free(origin);
        const session_id = try ref_mod.decodePathComponentAlloc(gpa, entry.path[sep + 1 ..]);
        errdefer gpa.free(session_id);

        try refs.append(gpa, .{
            .path = try std.fmt.allocPrint(gpa, "refs/sessions/{s}", .{entry.path}),
            .origin = origin,
            .session_id = session_id,
            .hash = hash,
        });
    }

    return refs.toOwnedSlice(gpa);
}

fn freeLocalRefs(gpa: std.mem.Allocator, refs: []const LocalRef) void {
    for (refs) |local_ref| {
        gpa.free(local_ref.path);
        gpa.free(local_ref.origin);
        gpa.free(local_ref.session_id);
    }
    if (refs.len > 0) gpa.free(refs);
}

fn freeRemoteRefs(gpa: std.mem.Allocator, refs: []const RemoteRef) void {
    for (refs) |remote_ref| {
        gpa.free(remote_ref.path);
        gpa.free(remote_ref.origin);
        gpa.free(remote_ref.session_id);
    }
    if (refs.len > 0) gpa.free(refs);
}

fn markStepChain(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    reachable: *std.AutoHashMap([64]u8, void),
    head_hash: store_mod.Hash,
) !void {
    var cursor: ?store_mod.Hash = head_hash;
    while (cursor) |current| {
        const current_hex = current.toHex();
        if (reachable.contains(current_hex)) break;
        try reachable.put(current_hex, {});

        var parsed_step = try store.readStep(io, gpa, current);
        defer parsed_step.deinit();
        try markTree(io, gpa, store, reachable, try store_mod.Hash.fromHex(parsed_step.value.tree));
        cursor = if (parsed_step.value.parent) |parent| try store_mod.Hash.fromHex(parent) else null;
    }
}

fn markTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    reachable: *std.AutoHashMap([64]u8, void),
    tree_hash: store_mod.Hash,
) !void {
    const tree_hex = tree_hash.toHex();
    if (reachable.contains(tree_hex)) return;
    try reachable.put(tree_hex, {});

    var parsed_tree = try store.readTree(io, gpa, tree_hash);
    defer parsed_tree.deinit();
    for (parsed_tree.value.entries) |entry| {
        try reachable.put(try parseHashHex(entry.blob), {});
    }
}

fn isAncestorInStore(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    ancestor: store_mod.Hash,
    descendant: store_mod.Hash,
) !bool {
    if (ancestor.eql(descendant)) return true;

    var cursor: ?store_mod.Hash = descendant;
    while (cursor) |current| {
        if (current.eql(ancestor)) return true;
        var parsed = store.readStep(io, gpa, current) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer parsed.deinit();
        cursor = if (parsed.value.parent) |parent| try store_mod.Hash.fromHex(parent) else null;
    }
    return false;
}

fn fetchReachableFromRemote(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    client: *S3Client,
    head_hash: store_mod.Hash,
    seen: *std.AutoHashMap([64]u8, void),
    result: *PullResult,
) !void {
    var stack = std.ArrayList([64]u8).empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, head_hash.toHex());

    while (stack.pop()) |current_hex| {
        if (seen.contains(current_hex)) continue;
        try seen.put(current_hex, {});

        if (try store.index.hasObject(&current_hex)) {
            result.skipped_objects += 1;
        } else {
            const key = try objectKeyAlloc(gpa, client.remote.config.prefix, current_hex);
            defer gpa.free(key);
            const remote_bytes = try client.getObjectAlloc(key);
            defer gpa.free(remote_bytes);

            const plain = try decodeRemoteObjectAlloc(gpa, current_hex, remote_bytes, client.remote.encryption_secret);
            defer gpa.free(plain);
            const actual_hex = store_mod.Hash.ofBytes(plain).toHex();
            if (!std.mem.eql(u8, &actual_hex, &current_hex)) {
                return error.ObjectHashMismatch;
            }

            try writeFetchedObject(io, store, current_hex, plain);
            result.downloaded_objects += 1;
        }

        const hash = try store_mod.Hash.fromHex(&current_hex);
        try appendObjectChildren(io, gpa, store, hash, &stack);
    }
}

fn appendObjectChildren(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    hash: store_mod.Hash,
    stack: *std.ArrayList([64]u8),
) !void {
    const raw = try store.readBlob(io, gpa, hash);
    defer gpa.free(raw);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    if (std.json.parseFromSlice(object_mod.Step, aa, raw, .{ .allocate = .alloc_always })) |parsed_step| {
        defer parsed_step.deinit();
        if (std.mem.eql(u8, parsed_step.value.type, "step")) {
            try stack.append(gpa, try parseHashHex(parsed_step.value.tree));
            if (parsed_step.value.parent) |parent| {
                try stack.append(gpa, try parseHashHex(parent));
            }
            return;
        }
    } else |_| {}

    if (std.json.parseFromSlice(object_mod.Tree, aa, raw, .{ .allocate = .alloc_always })) |parsed_tree| {
        defer parsed_tree.deinit();
        if (std.mem.eql(u8, parsed_tree.value.type, "tree")) {
            for (parsed_tree.value.entries) |entry| {
                try stack.append(gpa, try parseHashHex(entry.blob));
            }
            return;
        }
    } else |_| {}
}

fn writeFetchedObject(
    io: std.Io,
    store: *store_mod.Store,
    expected_hex: [64]u8,
    plain: []const u8,
) !void {
    const written = try object_mod.writeDetailed(io, store.root, plain);
    if (!written.hash.eql(try store_mod.Hash.fromHex(&expected_hex))) return error.ObjectHashMismatch;
    try store.index.insertObject(&expected_hex, try classifyKindName(std.heap.page_allocator, plain), written.size);
}

fn classifyKindName(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    if (std.json.parseFromSlice(object_mod.Tree, aa, raw, .{ .allocate = .alloc_always })) |parsed_tree| {
        defer parsed_tree.deinit();
        if (std.mem.eql(u8, parsed_tree.value.type, "tree")) return "tree";
    } else |_| {}
    if (std.json.parseFromSlice(object_mod.Step, aa, raw, .{ .allocate = .alloc_always })) |parsed_step| {
        defer parsed_step.deinit();
        if (std.mem.eql(u8, parsed_step.value.type, "step")) return "step";
    } else |_| {}
    return "blob";
}

fn prefixedKeyAlloc(gpa: std.mem.Allocator, prefix_raw: []const u8, suffix: []const u8) ![]u8 {
    const prefix = std.mem.trim(u8, prefix_raw, "/");
    if (prefix.len == 0) return gpa.dupe(u8, suffix);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, suffix });
}

fn objectKeyAlloc(gpa: std.mem.Allocator, prefix_raw: []const u8, hash_hex: [64]u8) ![]u8 {
    var path_buf: [73]u8 = undefined;
    const suffix = std.fmt.bufPrint(&path_buf, "objects/{s}/{s}", .{ hash_hex[0..2], hash_hex[2..] }) catch unreachable;
    return prefixedKeyAlloc(gpa, prefix_raw, suffix);
}

fn canonicalUriAlloc(gpa: std.mem.Allocator, remote: ResolvedRemote, key: []const u8) ![]u8 {
    if (key.len == 0) return std.fmt.allocPrint(gpa, "/{s}", .{remote.config.bucket});
    return std.fmt.allocPrint(gpa, "/{s}/{s}", .{ remote.config.bucket, key });
}

fn requestUrlAlloc(gpa: std.mem.Allocator, endpoint: []const u8, canonical_uri: []const u8, canonical_query: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, endpoint, "/");
    if (canonical_query.len == 0) return std.fmt.allocPrint(gpa, "{s}{s}", .{ trimmed, canonical_uri });
    return std.fmt.allocPrint(gpa, "{s}{s}?{s}", .{ trimmed, canonical_uri, canonical_query });
}

fn hostHeaderAlloc(gpa: std.mem.Allocator, endpoint_uri: std.Uri) ![]u8 {
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try endpoint_uri.getHost(&host_buf);
    const protocol = std.http.Client.Protocol.fromUri(endpoint_uri) orelse return error.InvalidRemoteEndpoint;
    const default_port = switch (protocol) {
        .plain => @as(u16, 80),
        .tls => @as(u16, 443),
    };
    if (endpoint_uri.port) |port| {
        if (port != default_port) {
            return std.fmt.allocPrint(gpa, "{s}:{d}", .{ host.bytes, port });
        }
    }
    return gpa.dupe(u8, host.bytes);
}

fn authorizationHeaderAlloc(
    gpa: std.mem.Allocator,
    remote: ResolvedRemote,
    date_stamp: []const u8,
    scope: []const u8,
    signed_headers: []const u8,
    string_to_sign: []const u8,
) ![]u8 {
    var k_date: [32]u8 = undefined;
    const aws_secret = try std.fmt.allocPrint(gpa, "AWS4{s}", .{remote.secret_key});
    defer gpa.free(aws_secret);
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_date, date_stamp, aws_secret);

    var k_region: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_region, remote.config.region, &k_date);
    var k_service: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_service, "s3", &k_region);
    var signing_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signing_key, "aws4_request", &k_service);

    var signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, string_to_sign, &signing_key);
    const signature_hex = try std.fmt.allocPrint(gpa, "{x}", .{signature});
    defer gpa.free(signature_hex);

    return std.fmt.allocPrint(
        gpa,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ remote.access_key, scope, signed_headers, signature_hex },
    );
}

fn listQueryAlloc(gpa: std.mem.Allocator, prefix: []const u8, continuation: ?[]const u8) ![]u8 {
    const encoded_prefix = try percentEncodeAlloc(gpa, prefix, false);
    defer gpa.free(encoded_prefix);
    if (continuation) |token| {
        const encoded_token = try percentEncodeAlloc(gpa, token, false);
        defer gpa.free(encoded_token);
        return std.fmt.allocPrint(gpa, "continuation-token={s}&list-type=2&prefix={s}", .{
            encoded_token,
            encoded_prefix,
        });
    }
    return std.fmt.allocPrint(gpa, "list-type=2&prefix={s}", .{encoded_prefix});
}

fn percentEncodeAlloc(gpa: std.mem.Allocator, text: []const u8, allow_slash: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (text) |byte| {
        const keep = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or
            byte == '_' or
            byte == '.' or
            byte == '~' or
            (allow_slash and byte == '/');
        if (keep) {
            try out.append(gpa, byte);
        } else {
            var encoded: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&encoded, "%{X:0>2}", .{byte}) catch unreachable;
            try out.appendSlice(gpa, &encoded);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn encodeRemoteObjectAlloc(
    gpa: std.mem.Allocator,
    object_hash_hex: [64]u8,
    plain: []const u8,
    encryption_secret: ?[]const u8,
) ![]u8 {
    if (encryption_secret) |secret| {
        const key = deriveKey(secret);
        var nonce: [std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length]u8 = undefined;
        nonceForObject(&nonce, key, object_hash_hex);
        const ciphertext = try gpa.alloc(u8, plain.len);
        errdefer gpa.free(ciphertext);
        var tag: [std.crypto.aead.aes_gcm.Aes256Gcm.tag_length]u8 = undefined;
        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(ciphertext, &tag, plain, &object_hash_hex, nonce, key);

        var payload = try gpa.alloc(u8, payload_magic.len + 1 + nonce.len + tag.len + ciphertext.len);
        errdefer gpa.free(payload);
        @memcpy(payload[0..payload_magic.len], payload_magic);
        payload[payload_magic.len] = payload_flag_encrypted;
        @memcpy(payload[payload_magic.len + 1 ..][0..nonce.len], &nonce);
        @memcpy(payload[payload_magic.len + 1 + nonce.len ..][0..tag.len], &tag);
        @memcpy(payload[payload_magic.len + 1 + nonce.len + tag.len ..], ciphertext);
        gpa.free(ciphertext);
        return payload;
    }

    var payload = try gpa.alloc(u8, payload_magic.len + 1 + plain.len);
    @memcpy(payload[0..payload_magic.len], payload_magic);
    payload[payload_magic.len] = 0;
    @memcpy(payload[payload_magic.len + 1 ..], plain);
    return payload;
}

fn decodeRemoteObjectAlloc(
    gpa: std.mem.Allocator,
    object_hash_hex: [64]u8,
    payload: []const u8,
    encryption_secret: ?[]const u8,
) ![]u8 {
    if (payload.len < payload_magic.len + 1) return error.InvalidRemoteObjectFormat;
    if (!std.mem.eql(u8, payload[0..payload_magic.len], payload_magic)) return error.InvalidRemoteObjectFormat;

    const flags = payload[payload_magic.len];
    if ((flags & payload_flag_encrypted) == 0) {
        return gpa.dupe(u8, payload[payload_magic.len + 1 ..]);
    }

    const secret = encryption_secret orelse return error.MissingEncryptionSecret;
    const nonce_start = payload_magic.len + 1;
    const nonce_end = nonce_start + std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length;
    const tag_end = nonce_end + std.crypto.aead.aes_gcm.Aes256Gcm.tag_length;
    if (payload.len < tag_end) return error.InvalidRemoteObjectFormat;

    var nonce: [std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length]u8 = undefined;
    @memcpy(&nonce, payload[nonce_start..nonce_end]);
    var tag: [std.crypto.aead.aes_gcm.Aes256Gcm.tag_length]u8 = undefined;
    @memcpy(&tag, payload[nonce_end..tag_end]);
    const ciphertext = payload[tag_end..];

    const plain = try gpa.alloc(u8, ciphertext.len);
    errdefer gpa.free(plain);
    const key = deriveKey(secret);
    try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plain, ciphertext, tag, &object_hash_hex, nonce, key);
    return plain;
}

fn deriveKey(secret: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agit-remote-sync-v1");
    hasher.update(secret);
    hasher.final(&digest);
    return digest;
}

fn nonceForObject(nonce: *[std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length]u8, key: [32]u8, object_hash_hex: [64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&digest, &object_hash_hex, &key);
    @memcpy(nonce[0..], digest[0..nonce[0..].len]);
}

fn parseListRefsPage(gpa: std.mem.Allocator, body: []const u8, prefix_raw: []const u8) !ListRefsPage {
    var paths = std.ArrayList([]u8).empty;
    errdefer {
        for (paths.items) |path| gpa.free(@constCast(path));
        paths.deinit(gpa);
    }

    const prefix = std.mem.trim(u8, prefix_raw, "/");
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, body, start, "<Key>")) |key_open| {
        const key_begin = key_open + "<Key>".len;
        const key_close = std.mem.indexOfPos(u8, body, key_begin, "</Key>") orelse return error.InvalidRemoteResponse;
        const full_key = body[key_begin..key_close];
        const rel_path = try stripPrefixAlloc(gpa, prefix, full_key);
        errdefer gpa.free(rel_path);
        if (!std.mem.startsWith(u8, rel_path, "refs/sessions/")) {
            gpa.free(rel_path);
            start = key_close + "</Key>".len;
            continue;
        }

        start = key_close + "</Key>".len;
        try paths.append(gpa, rel_path);
    }

    const truncated = std.mem.indexOf(u8, body, "<IsTruncated>true</IsTruncated>") != null;
    const next_token = if (std.mem.indexOf(u8, body, "<NextContinuationToken>")) |token_open| blk: {
        const begin = token_open + "<NextContinuationToken>".len;
        const end = std.mem.indexOfPos(u8, body, begin, "</NextContinuationToken>") orelse return error.InvalidRemoteResponse;
        break :blk try gpa.dupe(u8, body[begin..end]);
    } else null;

    return .{
        .paths = try paths.toOwnedSlice(gpa),
        .truncated = truncated,
        .next_token = next_token,
    };
}

fn stripPrefixAlloc(gpa: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]u8 {
    if (prefix.len == 0) return gpa.dupe(u8, key);
    const prefix_with_slash = try std.fmt.allocPrint(gpa, "{s}/", .{prefix});
    defer gpa.free(prefix_with_slash);
    if (!std.mem.startsWith(u8, key, prefix_with_slash)) return error.InvalidRemoteResponse;
    return gpa.dupe(u8, key[prefix_with_slash.len..]);
}

fn parseHashHex(text: []const u8) ![64]u8 {
    var out: [64]u8 = undefined;
    if (text.len != out.len) return error.InvalidHash;
    @memcpy(&out, text);
    _ = try store_mod.Hash.fromHex(&out);
    return out;
}

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest}) catch unreachable;
    return hex;
}

test "remote object envelope round-trips plaintext" {
    const hash_hex = store_mod.Hash.ofBytes("hello").toHex();
    const encoded = try encodeRemoteObjectAlloc(std.testing.allocator, hash_hex, "hello", null);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeRemoteObjectAlloc(std.testing.allocator, hash_hex, encoded, null);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello", decoded);
}

test "remote object envelope round-trips encrypted" {
    const hash_hex = store_mod.Hash.ofBytes("hello").toHex();
    const encoded = try encodeRemoteObjectAlloc(std.testing.allocator, hash_hex, "hello", "secret");
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(!std.mem.eql(u8, encoded[payload_magic.len + 1 ..], "hello"));

    const decoded = try decodeRemoteObjectAlloc(std.testing.allocator, hash_hex, encoded, "secret");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello", decoded);
}
