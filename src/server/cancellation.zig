const std = @import("std");
const jsonrpc = @import("../jsonrpc.zig");
const typed_codec = @import("../serde/typed_codec.zig");

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

    var arena = std.heap.ArenaAllocator.init(self.getAllocator());
    defer arena.deinit();
    const a = arena.allocator();

    const Params = struct {
        requestId: jsonrpc.RequestId,
    };
    const ParamsMapper = typed_codec.defaultMapper(Params);
    const parsed = typed_codec.valueToTyped(a, Params, ParamsMapper, params) catch return;
    const rid = parsed.requestId;

    self.active_requests_mutex.lock();
    defer self.active_requests_mutex.unlock();
    for (self.active_requests.items) |active| {
        if (active.id.eql(rid)) {
            active.cancelled.store(true, .release);
        }
    }
}
