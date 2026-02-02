const std = @import("std");
const json = std.json;
const posix = std.posix;
const c = std.c;
const jsonrpc = @import("jsonrpc.zig");

pub const Transport = struct {
    readFn: *const fn (*Transport, std.mem.Allocator) anyerror!?jsonrpc.Message,
    writeFn: *const fn (*Transport, []const u8) anyerror!void,
    closeFn: *const fn (*Transport) void,

    pub fn read(self: *Transport, allocator: std.mem.Allocator) !?jsonrpc.Message {
        return self.readFn(self, allocator);
    }

    pub fn write(self: *Transport, data: []const u8) !void {
        return self.writeFn(self, data);
    }

    pub fn close(self: *Transport) void {
        self.closeFn(self);
    }

    pub fn writeMessage(self: *Transport, msg: jsonrpc.Message, allocator: std.mem.Allocator) !void {
        const data = try msg.stringify(allocator);
        defer allocator.free(data);
        try self.write(data);
    }
};

pub const StdioTransport = struct {
    transport: Transport,
    read_buffer: std.ArrayList(u8),
    line_buffer: [8192]u8,
    line_len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StdioTransport {
        return .{
            .transport = .{
                .readFn = readImpl,
                .writeFn = writeImpl,
                .closeFn = closeImpl,
            },
            .read_buffer = .empty,
            .line_buffer = undefined,
            .line_len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StdioTransport) void {
        self.read_buffer.deinit(self.allocator);
    }

    pub fn asTransport(self: *StdioTransport) *Transport {
        return &self.transport;
    }

    fn readImpl(transport_ptr: *Transport, allocator: std.mem.Allocator) anyerror!?jsonrpc.Message {
        const self: *StdioTransport = @fieldParentPtr("transport", transport_ptr);

        while (true) {
            self.line_len = 0;

            while (self.line_len < self.line_buffer.len) {
                var buf: [1]u8 = undefined;
                const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return err,
                };

                if (n == 0) {
                    return null;
                }

                if (buf[0] == '\n') {
                    break;
                }

                self.line_buffer[self.line_len] = buf[0];
                self.line_len += 1;
            }

            if (self.line_len == 0) {
                continue; // ignore blank lines
            }

            return try jsonrpc.Message.parse(allocator, self.line_buffer[0..self.line_len]);
        }
    }

    fn writeImpl(_: *Transport, data: []const u8) anyerror!void {
        _ = c.write(posix.STDOUT_FILENO, data.ptr, data.len);
        _ = c.write(posix.STDOUT_FILENO, "\n", 1);
    }

    fn closeImpl(_: *Transport) void {}
};

pub const BufferedTransport = struct {
    transport: Transport,
    input: std.ArrayList(u8),
    output: std.ArrayList(u8),
    input_pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BufferedTransport {
        return .{
            .transport = .{
                .readFn = readImpl,
                .writeFn = writeImpl,
                .closeFn = closeImpl,
            },
            .input = .empty,
            .output = .empty,
            .input_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferedTransport) void {
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
    }

    pub fn asTransport(self: *BufferedTransport) *Transport {
        return &self.transport;
    }

    pub fn setInput(self: *BufferedTransport, data: []const u8) !void {
        self.input.clearRetainingCapacity();
        try self.input.appendSlice(self.allocator, data);
        self.input_pos = 0;
    }

    pub fn getOutput(self: *BufferedTransport) []const u8 {
        return self.output.items;
    }

    pub fn clearOutput(self: *BufferedTransport) void {
        self.output.clearRetainingCapacity();
    }

    fn readImpl(transport_ptr: *Transport, allocator: std.mem.Allocator) anyerror!?jsonrpc.Message {
        const self: *BufferedTransport = @fieldParentPtr("transport", transport_ptr);

        while (self.input_pos < self.input.items.len) {
            const start = self.input_pos;
            var end = start;
            while (end < self.input.items.len and self.input.items[end] != '\n') {
                end += 1;
            }

            if (end >= self.input.items.len) {
                return null;
            }

            const line = self.input.items[start..end];
            self.input_pos = end + 1;

            if (line.len == 0) {
                continue; // ignore blank lines
            }

            return try jsonrpc.Message.parse(allocator, line);
        }

        return null;
    }

    fn writeImpl(transport_ptr: *Transport, data: []const u8) anyerror!void {
        const self: *BufferedTransport = @fieldParentPtr("transport", transport_ptr);
        try self.output.appendSlice(self.allocator, data);
        try self.output.append(self.allocator, '\n');
    }

    fn closeImpl(_: *Transport) void {}
};

test "BufferedTransport basic" {
    var transport_obj = BufferedTransport.init(std.testing.allocator);
    defer transport_obj.deinit();

    try transport_obj.setInput("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}\n");

    const msg = try transport_obj.asTransport().read(std.testing.allocator);
    defer {
        if (msg) |m| {
            jsonrpc.Message.freeMessage(std.testing.allocator, m);
        }
    }

    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .notification);
    try std.testing.expectEqualStrings("test", msg.?.notification.method);
}
