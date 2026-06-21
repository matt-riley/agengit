pub const SessionRow = struct {
    origin: []const u8,
    session_id: []const u8,
    head_hash: ?[]const u8,
    updated_at: i64,
};

/// A step row returned by index queries.
pub const StepRow = struct {
    hash: []const u8,
    turn_id: []const u8,
    parent_hash: ?[]const u8,
    tree_hash: []const u8,
    timestamp: i64,
    model: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
};

pub const TimelineOptions = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    limit: usize,
};

pub const StatsOptions = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub const StatsSummaryRow = struct {
    session_count: i64 = 0,
    step_count: i64 = 0,
    turn_count: i64 = 0,
    first_timestamp: ?i64 = null,
    last_timestamp: ?i64 = null,
};

pub const SessionStatsRow = struct {
    origin: []const u8,
    session_id: []const u8,
    step_count: i64,
    turn_count: i64,
    first_timestamp: ?i64,
    last_timestamp: ?i64,
};

pub const ToolCountRow = struct {
    tool_name: []const u8,
    count: i64,
};

pub const WatchOptions = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since_ms: ?i64 = null,
    after_rowid: i64,
    limit: usize,
};

pub const TimelineRow = struct {
    rowid: i64 = 0,
    hash: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    timestamp: i64,
    model: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
    preview: ?[]const u8 = null,
};

pub const SearchOptions = struct {
    match_query: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    limit: usize,
    context_tokens: usize,
};

pub const SearchRow = struct {
    entry_kind: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    step_hash: []const u8,
    timestamp: i64,
    label: []const u8,
    snippet: []const u8,
};

pub const RecallRow = struct {
    hash: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    timestamp: i64,
    model: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
    preview: ?[]const u8 = null,
};

pub const RecallPathOptions = struct {
    path: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    limit: usize,
};
