const std = @import("std");
const row_types = @import("rows.zig");

const SessionRow = row_types.SessionRow;
const StepRow = row_types.StepRow;
const TimelineRow = row_types.TimelineRow;
const RecallRow = row_types.RecallRow;
const SessionStatsRow = row_types.SessionStatsRow;
const ToolCountRow = row_types.ToolCountRow;
const SearchRow = row_types.SearchRow;

pub fn freeSessionRow(gpa: std.mem.Allocator, r: SessionRow) void {
    gpa.free(r.origin);
    gpa.free(r.session_id);
    if (r.head_hash) |h| gpa.free(h);
}

pub fn freeStepRow(gpa: std.mem.Allocator, r: StepRow) void {
    gpa.free(r.hash);
    gpa.free(r.turn_id);
    if (r.parent_hash) |p| gpa.free(p);
    gpa.free(r.tree_hash);
    if (r.model) |value| gpa.free(value);
    if (r.outcome) |value| gpa.free(value);
    if (r.git_commit) |value| gpa.free(value);
    if (r.git_branch) |value| gpa.free(value);
}

pub fn freeTimelineRow(gpa: std.mem.Allocator, row: TimelineRow) void {
    gpa.free(row.hash);
    gpa.free(row.origin);
    gpa.free(row.session_id);
    gpa.free(row.turn_id);
    if (row.model) |value| gpa.free(value);
    if (row.git_commit) |value| gpa.free(value);
    if (row.git_branch) |value| gpa.free(value);
    if (row.preview) |value| gpa.free(value);
}

pub fn freeRecallRow(gpa: std.mem.Allocator, row: RecallRow) void {
    gpa.free(row.hash);
    gpa.free(row.origin);
    gpa.free(row.session_id);
    gpa.free(row.turn_id);
    if (row.model) |value| gpa.free(value);
    if (row.outcome) |value| gpa.free(value);
    if (row.git_commit) |value| gpa.free(value);
    if (row.git_branch) |value| gpa.free(value);
    if (row.preview) |value| gpa.free(value);
}

pub fn freeRecallRows(gpa: std.mem.Allocator, rows: []const RecallRow) void {
    for (rows) |row| freeRecallRow(gpa, row);
    gpa.free(rows);
}

pub fn freeSessionRows(gpa: std.mem.Allocator, rows: []const SessionRow) void {
    for (rows) |r| freeSessionRow(gpa, r);
    gpa.free(rows);
}

pub fn freeStepRows(gpa: std.mem.Allocator, rows: []const StepRow) void {
    for (rows) |r| freeStepRow(gpa, r);
    gpa.free(rows);
}

pub fn freeTimelineRows(gpa: std.mem.Allocator, rows: []const TimelineRow) void {
    for (rows) |row| freeTimelineRow(gpa, row);
    gpa.free(rows);
}

pub fn freeSessionStatsRow(gpa: std.mem.Allocator, row: SessionStatsRow) void {
    gpa.free(row.origin);
    gpa.free(row.session_id);
}

pub fn freeSessionStatsRows(gpa: std.mem.Allocator, rows: []const SessionStatsRow) void {
    for (rows) |row| freeSessionStatsRow(gpa, row);
    gpa.free(rows);
}

pub fn freeToolCountRow(gpa: std.mem.Allocator, row: ToolCountRow) void {
    gpa.free(row.tool_name);
}

pub fn freeToolCountRows(gpa: std.mem.Allocator, rows: []const ToolCountRow) void {
    for (rows) |row| freeToolCountRow(gpa, row);
    gpa.free(rows);
}

pub fn freeSearchRow(gpa: std.mem.Allocator, row: SearchRow) void {
    gpa.free(row.entry_kind);
    gpa.free(row.origin);
    gpa.free(row.session_id);
    gpa.free(row.turn_id);
    gpa.free(row.step_hash);
    gpa.free(row.label);
    gpa.free(row.snippet);
}

pub fn freeSearchRows(gpa: std.mem.Allocator, rows: []const SearchRow) void {
    for (rows) |row| freeSearchRow(gpa, row);
    gpa.free(rows);
}
