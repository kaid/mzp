const std = @import("std");
const jsonrpc = @import("../jsonrpc.zig");

pub fn registerActiveRequest(self: anytype, req: *(@TypeOf(self.*).ActiveRequest)) void {
    self.active_requests_mutex.lock();
    defer self.active_requests_mutex.unlock();
    self.active_requests.append(self.getAllocator(), req) catch {};
}

pub fn unregisterActiveRequest(self: anytype, req: *(@TypeOf(self.*).ActiveRequest)) void {
    self.active_requests_mutex.lock();
    defer self.active_requests_mutex.unlock();
    var i: usize = 0;
    while (i < self.active_requests.items.len) : (i += 1) {
        if (self.active_requests.items[i] == req) {
            _ = self.active_requests.swapRemove(i);
            break;
        }
    }
}

pub fn handleCancelledNotification(self: anytype, notif: jsonrpc.Notification) void {
    const params = notif.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const rid_val = obj.get("requestId") orelse return;
    const rid: jsonrpc.RequestId = switch (rid_val) {
        .string => |s| .{ .string = s },
        .integer => |n| .{ .number = n },
        .number_string => |s| blk: {
            const parsed = std.fmt.parseInt(i64, s, 10) catch return;
            break :blk .{ .number = parsed };
        },
        else => return,
    };

    self.active_requests_mutex.lock();
    defer self.active_requests_mutex.unlock();
    for (self.active_requests.items) |active| {
        if (active.id.eql(rid)) {
            active.cancelled.store(true, .release);
        }
    }
}

