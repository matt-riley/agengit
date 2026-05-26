const std = @import("std");

pub const BufPool = struct {
    gpa: std.mem.Allocator,
    slots: [bucket_count]?[]u8 = [_]?[]u8{null} ** bucket_count,

    const min_bits = 12; // 4 KiB
    const max_bits = 25; // 32 MiB
    const bucket_count = max_bits - min_bits + 1;

    pub fn init(gpa: std.mem.Allocator) BufPool {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *BufPool) void {
        for (self.slots) |maybe_buf| {
            if (maybe_buf) |buf| self.gpa.free(buf);
        }
        self.* = undefined;
    }

    pub fn acquire(self: *BufPool, size_hint: usize) ![]u8 {
        const bucket = bucketFor(size_hint);
        const size = bucketSize(bucket);
        if (self.slots[bucket]) |buf| {
            self.slots[bucket] = null;
            return buf;
        }
        return self.gpa.alloc(u8, size);
    }

    pub fn release(self: *BufPool, buf: []u8) void {
        const bucket = bucketForExact(buf.len) orelse {
            self.gpa.free(buf);
            return;
        };
        if (self.slots[bucket]) |existing| {
            self.gpa.free(existing);
        }
        self.slots[bucket] = buf;
    }

    fn bucketFor(size_hint: usize) usize {
        const wanted = @max(size_hint, @as(usize, 1) << min_bits);
        var bits: usize = min_bits;
        var size: usize = @as(usize, 1) << min_bits;
        while (size < wanted and bits < max_bits) : (bits += 1) {
            size <<= 1;
        }
        return bits - min_bits;
    }

    fn bucketForExact(size: usize) ?usize {
        if (size == 0) return null;
        var bits: usize = min_bits;
        var probe: usize = @as(usize, 1) << min_bits;
        while (bits <= max_bits) : (bits += 1) {
            if (probe == size) return bits - min_bits;
            probe <<= 1;
        }
        return null;
    }

    fn bucketSize(bucket: usize) usize {
        return @as(usize, 1) << @intCast(min_bits + bucket);
    }
};

test "BufPool rounds to the next power of two" {
    var pool = BufPool.init(std.testing.allocator);
    defer pool.deinit();

    const small = try pool.acquire(1);
    defer pool.release(small);
    try std.testing.expectEqual(@as(usize, 4096), small.len);

    const mid = try pool.acquire(6000);
    defer pool.release(mid);
    try std.testing.expectEqual(@as(usize, 8192), mid.len);
}

test "BufPool reuses a released buffer from the same bucket" {
    var pool = BufPool.init(std.testing.allocator);
    defer pool.deinit();

    const first = try pool.acquire(5000);
    const first_ptr = @intFromPtr(first.ptr);
    pool.release(first);

    const second = try pool.acquire(4097);
    defer pool.release(second);
    try std.testing.expectEqual(first_ptr, @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(usize, 8192), second.len);
}
