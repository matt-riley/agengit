const std = @import("std");

pub const GetHomeError = error{
    OutOfMemory,
    InvalidWtf8,
    MissingHOME,
};

/// Return the user's home directory from the process environment.
/// POSIX systems conventionally use HOME; Windows commonly uses USERPROFILE.
pub fn getAlloc(gpa: std.mem.Allocator, environ: std.process.Environ) GetHomeError![]u8 {
    return environ.getAlloc(gpa, "HOME") catch |home_err| switch (home_err) {
        error.EnvironmentVariableMissing => environ.getAlloc(gpa, "USERPROFILE") catch |profile_err| switch (profile_err) {
            error.EnvironmentVariableMissing => error.MissingHOME,
            else => |err| err,
        },
        else => |err| err,
    };
}

test "getAlloc reports missing home for an empty environment" {
    try std.testing.expectError(error.MissingHOME, getAlloc(std.testing.allocator, .empty));
}
