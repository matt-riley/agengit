const std = @import("std");

const config_schema_text = @embedFile("schema/release-please-config.schema.json");
const manifest_schema_text = @embedFile("schema/release-please-manifest.schema.json");

const ValidationError = struct {
    path: []const u8,
    message: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    const ok = try runCheck(init.io, std.Io.Dir.cwd(), init.gpa, &stderr);
    try stderr.flush();
    if (!ok) std.process.exit(1);
}

pub fn runCheck(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    stderr: *std.Io.File.Writer,
) !bool {
    var ok = true;
    ok = (try validateJsonFile(io, root, gpa, stderr, "release-please-config.json", config_schema_text, .config)) and ok;
    ok = (try validateJsonFile(io, root, gpa, stderr, ".release-please-manifest.json", manifest_schema_text, .manifest)) and ok;
    return ok;
}

const ValidationMode = enum {
    config,
    manifest,
};

fn validateJsonFile(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    stderr: *std.Io.File.Writer,
    file_path: []const u8,
    schema_text: []const u8,
    mode: ValidationMode,
) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    const file_text = try root.readFileAlloc(io, file_path, aa, .unlimited);
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, aa, schema_text, .{});
    const document = try std.json.parseFromSliceLeaky(std.json.Value, aa, file_text, .{});

    var errors: std.ArrayList(ValidationError) = .empty;
    defer errors.deinit(aa);

    const root_path = try std.fmt.allocPrint(aa, "{s}", .{file_path});
    const schema_ok = try validateValue(aa, schema, schema, document, root_path, &errors, true);

    var semantic_ok = true;
    if (mode == .config and schema_ok) {
        semantic_ok = try validateExtraFilePaths(io, root, aa, document, file_path, &errors);
    }

    if (!schema_ok or !semantic_ok) {
        for (errors.items) |err| {
            try stderr.interface.print("error: {s}: {s}\n", .{ err.path, err.message });
        }
        return false;
    }

    return true;
}

fn validateValue(
    gpa: std.mem.Allocator,
    schema_root: std.json.Value,
    schema_value: std.json.Value,
    document: std.json.Value,
    path: []const u8,
    errors: *std.ArrayList(ValidationError),
    emit_errors: bool,
) !bool {
    switch (schema_value) {
        .bool => |allow| {
            if (!allow and emit_errors) try addError(gpa, errors, path, "schema disallows this value");
            return allow;
        },
        .object => |schema_obj| {
            if (schema_obj.get("$ref")) |ref_value| {
                if (ref_value != .string) {
                    if (emit_errors) try addError(gpa, errors, path, "schema reference must be a string");
                    return false;
                }
                return validateValue(gpa, schema_root, try resolveRef(schema_root, ref_value.string), document, path, errors, emit_errors);
            }

            if (schema_obj.get("allOf")) |all_of| {
                if (all_of != .array) {
                    if (emit_errors) try addError(gpa, errors, path, "schema allOf must be an array");
                    return false;
                }
                var ok = true;
                for (all_of.array.items) |subschema| {
                    ok = (try validateValue(gpa, schema_root, subschema, document, path, errors, emit_errors)) and ok;
                }
                if (!ok) return false;
            }

            if (schema_obj.get("anyOf")) |any_of| {
                if (any_of != .array) {
                    if (emit_errors) try addError(gpa, errors, path, "schema anyOf must be an array");
                    return false;
                }
                for (any_of.array.items) |subschema| {
                    if (try validateValue(gpa, schema_root, subschema, document, path, errors, false)) {
                        return true;
                    }
                }
                if (emit_errors) try addError(gpa, errors, path, "value does not match any allowed schema shape");
                return false;
            }

            if (schema_obj.get("type")) |expected_type| {
                if (expected_type != .string) {
                    if (emit_errors) try addError(gpa, errors, path, "schema type must be a string");
                    return false;
                }
                if (!matchesType(expected_type.string, document)) {
                    if (emit_errors) {
                        const message = try std.fmt.allocPrint(
                            gpa,
                            "expected {s}, got {s}",
                            .{ expected_type.string, valueTypeName(document) },
                        );
                        try addError(gpa, errors, path, message);
                    }
                    return false;
                }
            }

            if (schema_obj.get("enum")) |enum_values| {
                if (enum_values != .array) {
                    if (emit_errors) try addError(gpa, errors, path, "schema enum must be an array");
                    return false;
                }
                var found = false;
                for (enum_values.array.items) |candidate| {
                    if (jsonValueEqual(candidate, document)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (emit_errors) try addError(gpa, errors, path, "value is not one of the allowed enum entries");
                    return false;
                }
            }

            if (schema_obj.get("required")) |required_fields| {
                if (document != .object) {
                    if (emit_errors) try addError(gpa, errors, path, "required fields need an object value");
                    return false;
                }
                if (required_fields != .array) {
                    if (emit_errors) try addError(gpa, errors, path, "schema required must be an array");
                    return false;
                }
                for (required_fields.array.items) |field| {
                    if (field != .string) continue;
                    if (document.object.get(field.string) == null) {
                        if (emit_errors) {
                            const field_path = try appendObjectPath(gpa, path, field.string);
                            try addError(gpa, errors, field_path, "missing required field");
                        }
                        return false;
                    }
                }
            }

            if (schema_obj.get("properties")) |properties| {
                if (document == .object) {
                    if (properties != .object) {
                        if (emit_errors) try addError(gpa, errors, path, "schema properties must be an object");
                        return false;
                    }
                    var iter = properties.object.iterator();
                    while (iter.next()) |entry| {
                        if (document.object.get(entry.key_ptr.*)) |field_value| {
                            const field_path = try appendObjectPath(gpa, path, entry.key_ptr.*);
                            if (!(try validateValue(gpa, schema_root, entry.value_ptr.*, field_value, field_path, errors, emit_errors))) {
                                return false;
                            }
                        }
                    }
                }
            }

            if (schema_obj.get("additionalProperties")) |additional| {
                if (document == .object) {
                    const declared = schema_obj.get("properties");
                    var iter = document.object.iterator();
                    while (iter.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const declared_property = if (declared) |properties| switch (properties) {
                            .object => properties.object.get(key),
                            else => null,
                        } else null;
                        if (declared_property != null) continue;

                        switch (additional) {
                            .bool => |allow| {
                                if (!allow) {
                                    if (emit_errors) {
                                        const field_path = try appendObjectPath(gpa, path, key);
                                        try addError(gpa, errors, field_path, "unexpected property");
                                    }
                                    return false;
                                }
                            },
                            else => {
                                const field_path = try appendObjectPath(gpa, path, key);
                                if (!(try validateValue(gpa, schema_root, additional, entry.value_ptr.*, field_path, errors, emit_errors))) {
                                    return false;
                                }
                            },
                        }
                    }
                }
            }

            if (schema_obj.get("items")) |items_schema| {
                if (document == .array) {
                    for (document.array.items, 0..) |item, index| {
                        const item_path = try appendIndexPath(gpa, path, index);
                        if (!(try validateValue(gpa, schema_root, items_schema, item, item_path, errors, emit_errors))) {
                            return false;
                        }
                    }
                }
            }

            return true;
        },
        else => {
            if (emit_errors) try addError(gpa, errors, path, "unsupported schema node");
            return false;
        },
    }
}

fn validateExtraFilePaths(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    document: std.json.Value,
    file_path: []const u8,
    errors: *std.ArrayList(ValidationError),
) !bool {
    if (document != .object) return false;
    const packages = document.object.get("packages") orelse return false;
    if (packages != .object) return false;

    var ok = true;
    var package_iter = packages.object.iterator();
    while (package_iter.next()) |package_entry| {
        const package_name = package_entry.key_ptr.*;
        if (package_entry.value_ptr.* != .object) continue;
        const extra_files = package_entry.value_ptr.object.get("extra-files") orelse continue;
        if (extra_files != .array) continue;

        for (extra_files.array.items, 0..) |item, index| {
            const maybe_path_value: ?std.json.Value = switch (item) {
                .string => item,
                .object => item.object.get("path"),
                else => continue,
            };
            const path_value = switch (maybe_path_value orelse continue) {
                .string => |value| value,
                else => continue,
            };
            if (!pathExists(io, root, path_value)) {
                ok = false;
                const err_path = try std.fmt.allocPrint(
                    gpa,
                    "{s}.packages.{s}.extra-files[{d}]",
                    .{ file_path, package_name, index },
                );
                try addError(gpa, errors, err_path, "references a path that does not exist in the repository");
            }
        }
    }
    return ok;
}

fn resolveRef(schema_root: std.json.Value, ref_path: []const u8) !std.json.Value {
    if (!std.mem.startsWith(u8, ref_path, "#/")) return error.UnsupportedSchemaRef;
    var current = schema_root;
    var parts = std.mem.splitScalar(u8, ref_path[2..], '/');
    while (parts.next()) |raw_part| {
        if (current != .object) return error.UnsupportedSchemaRef;
        const part = try decodeJsonPointerSegment(std.heap.page_allocator, raw_part);
        defer std.heap.page_allocator.free(part);
        current = current.object.get(part) orelse return error.UnsupportedSchemaRef;
    }
    return current;
}

fn decodeJsonPointerSegment(gpa: std.mem.Allocator, segment: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (segment[i] == '~' and i + 1 < segment.len) {
            switch (segment[i + 1]) {
                '0' => {
                    try out.append(gpa, '~');
                    i += 1;
                    continue;
                },
                '1' => {
                    try out.append(gpa, '/');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(gpa, segment[i]);
    }
    return try out.toOwnedSlice(gpa);
}

fn matchesType(expected: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, expected, "object")) return value == .object;
    if (std.mem.eql(u8, expected, "array")) return value == .array;
    if (std.mem.eql(u8, expected, "string")) return value == .string;
    if (std.mem.eql(u8, expected, "boolean")) return value == .bool;
    if (std.mem.eql(u8, expected, "number")) return value == .integer or value == .float;
    return false;
}

fn valueTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .integer, .float => "number",
        .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn jsonValueEqual(left: std.json.Value, right: std.json.Value) bool {
    return switch (left) {
        .null => right == .null,
        .bool => |v| right == .bool and right.bool == v,
        .integer => |v| right == .integer and right.integer == v,
        .float => |v| right == .float and right.float == v,
        .number_string => |v| right == .number_string and std.mem.eql(u8, right.number_string, v),
        .string => |v| right == .string and std.mem.eql(u8, right.string, v),
        else => false,
    };
}

fn appendObjectPath(gpa: std.mem.Allocator, path: []const u8, field: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ path, field });
}

fn appendIndexPath(gpa: std.mem.Allocator, path: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}[{d}]", .{ path, index });
}

fn addError(
    gpa: std.mem.Allocator,
    errors: *std.ArrayList(ValidationError),
    path: []const u8,
    message: []const u8,
) !void {
    try errors.append(gpa, .{
        .path = try gpa.dupe(u8, path),
        .message = try gpa.dupe(u8, message),
    });
}

fn pathExists(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    var file = root.openFile(io, path, .{}) catch |file_err| switch (file_err) {
        error.FileNotFound => {
            var dir = root.openDir(io, path, .{}) catch return false;
            dir.close(io);
            return true;
        },
        else => return false,
    };
    file.close(io);
    return true;
}

test "runCheck accepts current release-please files" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "release-please-config.json", "{\n  \"$schema\": \"https://example.invalid/config.json\",\n  \"packages\": {\n    \".\": {\n      \"release-type\": \"simple\",\n      \"draft\": true,\n      \"extra-files\": [\"README.md\"]\n    }\n  }\n}\n");
    try writeFile(io, tmp.dir, ".release-please-manifest.json", "{\n  \".\": \"1.13.0\"\n}\n");
    try writeFile(io, tmp.dir, "README.md", "# readme\n");

    try std.testing.expect(try runCheck(io, tmp.dir, gpa, &stderr));
}

test "runCheck rejects malformed release-please config" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "release-please-config.json", "{\n  \"packages\": {\n    \".\": {\n      \"draft\": \"yes\"\n    }\n  }\n}\n");
    try writeFile(io, tmp.dir, ".release-please-manifest.json", "{\n  \".\": \"1.13.0\"\n}\n");

    try std.testing.expect(!(try runCheck(io, tmp.dir, gpa, &stderr)));
}

fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try dir.createDirPath(io, path[0..sep]);
    }
    var file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeAll(io, content);
}
