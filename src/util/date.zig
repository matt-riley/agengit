const std = @import("std");

pub const day_ms: i64 = 24 * 60 * 60 * 1000;

pub fn parseUtcDateMidnight(text: []const u8) !i64 {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;

    const year = try std.fmt.parseInt(i64, text[0..4], 10);
    const month = try std.fmt.parseInt(i64, text[5..7], 10);
    const day = try std.fmt.parseInt(i64, text[8..10], 10);

    if (month < 1 or month > 12) return error.InvalidDate;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDate;

    const days = daysFromCivil(year, month, day);
    return try std.math.mul(i64, days, day_ms);
}

pub fn parseUtcDateEndExclusive(text: []const u8) !i64 {
    const start = try parseUtcDateMidnight(text);
    return try std.math.add(i64, start, day_ms);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn daysFromCivil(year_input: i64, month_input: i64, day: i64) i64 {
    var year = year_input;
    const month = month_input;
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp: i64 = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parseUtcDateMidnight parses UTC dates" {
    try std.testing.expectEqual(@as(i64, 0), try parseUtcDateMidnight("1970-01-01"));
    try std.testing.expectEqual(@as(i64, 86_400_000), try parseUtcDateMidnight("1970-01-02"));
    try std.testing.expectError(error.InvalidDate, parseUtcDateMidnight("1970-13-01"));
}

test "parseUtcDateEndExclusive advances one day" {
    try std.testing.expectEqual(@as(i64, 86_400_000), try parseUtcDateEndExclusive("1970-01-01"));
}
