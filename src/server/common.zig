const std = @import("std");
const json = std.json;
const types = @import("../types.zig");

pub const ToolCallMeta = struct {
    /// Progress token forwarded from `tools/call` params._meta.progressToken (if present).
    progressToken: ?types.ProgressToken = null,
    /// Task TTL forwarded from `tools/call` params.task (if present).
    ttl: ?u64 = null,
};

pub const CancellationToken = struct {
    cancelled: *const std.atomic.Value(bool),

    pub fn isCancelled(self: CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const ToolHandler = *const fn (
    user_data: ?*anyopaque,
    name: []const u8,
    arguments: ?json.Value,
    meta: ToolCallMeta,
    cancel: CancellationToken,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedCallToolResult;
