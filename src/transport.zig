const std = @import("std");
const json = std.json;
const jsonrpc = @import("jsonrpc.zig");

pub const Transport = struct {
    readFn: *const fn (*Transport, std.Io, std.mem.Allocator) anyerror!?jsonrpc.Message,
    writeFn: *const fn (*Transport, std.Io, []const u8) anyerror!void,
    closeFn: *const fn (*Transport, std.Io) void,

    pub fn read(self: *Transport, io: std.Io, allocator: std.mem.Allocator) !?jsonrpc.Message {
        return self.readFn(self, io, allocator);
    }

    pub fn write(self: *Transport, io: std.Io, data: []const u8) !void {
        return self.writeFn(self, io, data);
    }

    pub fn close(self: *Transport, io: std.Io) void {
        self.closeFn(self, io);
    }

    pub fn writeMessage(self: *Transport, io: std.Io, msg: jsonrpc.Message, allocator: std.mem.Allocator) !void {
        const data = try msg.stringify(allocator);
        defer allocator.free(data);
        try self.write(io, data);
    }
};

pub const StdioTransport = struct {
    transport: Transport,
    read_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    inited: bool = false,
    input_file: ?std.Io.File = null,
    output_file: ?std.Io.File = null,
    stdin_reader: std.Io.File.Reader = undefined,
    stdout_writer: std.Io.File.Writer = undefined,
    stdin_buf: [8192]u8 = undefined,
    stdout_buf: [8192]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) StdioTransport {
        return .{
            .transport = .{
                .readFn = readImpl,
                .writeFn = writeImpl,
                .closeFn = closeImpl,
            },
            .read_buffer = .empty,
            .allocator = allocator,
        };
    }

    /// Creates a stdio-like transport which reads from `input_file` and writes to `output_file`.
    /// The transport does not take ownership of the file handles; the caller is responsible
    /// for closing them.
    pub fn initWithFiles(allocator: std.mem.Allocator, input_file: std.Io.File, output_file: std.Io.File) StdioTransport {
        var t = init(allocator);
        t.input_file = input_file;
        t.output_file = output_file;
        return t;
    }

    pub fn deinit(self: *StdioTransport) void {
        self.read_buffer.deinit(self.allocator);
    }

    pub fn asTransport(self: *StdioTransport) *Transport {
        return &self.transport;
    }

    fn ensureInited(self: *StdioTransport, io: std.Io) void {
        if (self.inited) return;
        self.inited = true;
        const stdin_file = self.input_file orelse std.Io.File.stdin();
        const stdout_file = self.output_file orelse std.Io.File.stdout();
        self.stdin_reader = stdin_file.readerStreaming(io, self.stdin_buf[0..]);
        self.stdout_writer = stdout_file.writerStreaming(io, self.stdout_buf[0..]);
    }

    fn readImpl(transport_ptr: *Transport, io: std.Io, allocator: std.mem.Allocator) anyerror!?jsonrpc.Message {
        const self: *StdioTransport = @fieldParentPtr("transport", transport_ptr);
        self.ensureInited(io);

        while (true) {
            const line_opt = self.stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => return error.StreamTooLong,
            };
            const line = line_opt orelse return null;
            if (line.len == 0) {
                continue; // ignore blank lines
            }
            return try jsonrpc.Message.parse(allocator, line);
        }
    }

    fn writeImpl(transport_ptr: *Transport, io: std.Io, data: []const u8) anyerror!void {
        const self: *StdioTransport = @fieldParentPtr("transport", transport_ptr);
        self.ensureInited(io);
        try self.stdout_writer.interface.writeAll(data);
        try self.stdout_writer.interface.writeByte('\n');
        try self.stdout_writer.interface.flush();
    }

    fn closeImpl(_: *Transport, _: std.Io) void {}
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

    fn readImpl(transport_ptr: *Transport, _: std.Io, allocator: std.mem.Allocator) anyerror!?jsonrpc.Message {
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

    fn writeImpl(transport_ptr: *Transport, _: std.Io, data: []const u8) anyerror!void {
        const self: *BufferedTransport = @fieldParentPtr("transport", transport_ptr);
        try self.output.appendSlice(self.allocator, data);
        try self.output.append(self.allocator, '\n');
    }

    fn closeImpl(_: *Transport, _: std.Io) void {}
};

/// In-memory, blocking, line-delimited transport for tests and embedding.
/// `write()` sends one JSON-RPC message (without the trailing newline).
/// `read()` blocks until a message is available or the peer closes.
pub const DuplexTransport = struct {
    pub const Endpoint = struct {
        transport: Transport,
        allocator: std.mem.Allocator,
        inbound: *Channel,
        outbound: *Channel,

        pub fn asTransport(self: *Endpoint) *Transport {
            return &self.transport;
        }
    };

    const Channel = struct {
        allocator: std.mem.Allocator,
        queue: std.Io.Queue([]u8) = undefined,
        buf: [128][]u8 = undefined,

        fn init(self: *Channel, allocator: std.mem.Allocator) void {
            self.allocator = allocator;
            self.queue = std.Io.Queue([]u8).init(self.buf[0..]);
        }

        fn deinit(self: *Channel, io: std.Io) void {
            self.queue.close(io);
            while (true) {
                const msg_bytes = self.queue.getOneUncancelable(io) catch break;
                self.allocator.free(msg_bytes);
            }
        }
    };

    allocator: std.mem.Allocator,
    a_to_b: Channel = undefined,
    b_to_a: Channel = undefined,
    a: Endpoint = undefined,
    b: Endpoint = undefined,

    pub fn init(self: *DuplexTransport, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .a_to_b = undefined,
            .b_to_a = undefined,
            .a = undefined,
            .b = undefined,
        };

        self.a_to_b.init(allocator);
        self.b_to_a.init(allocator);

        self.a = .{
            .transport = .{
                .readFn = endpointRead,
                .writeFn = endpointWrite,
                .closeFn = endpointClose,
            },
            .allocator = allocator,
            .inbound = &self.b_to_a,
            .outbound = &self.a_to_b,
        };
        self.b = .{
            .transport = .{
                .readFn = endpointRead,
                .writeFn = endpointWrite,
                .closeFn = endpointClose,
            },
            .allocator = allocator,
            .inbound = &self.a_to_b,
            .outbound = &self.b_to_a,
        };
    }

    pub fn deinit(self: *DuplexTransport, io: std.Io) void {
        self.a_to_b.deinit(io);
        self.b_to_a.deinit(io);
        self.* = undefined;
    }

    pub fn endpointA(self: *DuplexTransport) *Endpoint {
        return &self.a;
    }

    pub fn endpointB(self: *DuplexTransport) *Endpoint {
        return &self.b;
    }

    fn endpointRead(transport_ptr: *Transport, io: std.Io, allocator: std.mem.Allocator) anyerror!?jsonrpc.Message {
        const ep: *Endpoint = @fieldParentPtr("transport", transport_ptr);
        const bytes = ep.inbound.queue.getOne(io) catch |err| switch (err) {
            error.Closed => return null,
            error.Canceled => return error.Canceled,
        };
        defer ep.allocator.free(bytes);
        return try jsonrpc.Message.parse(allocator, bytes);
    }

    fn endpointWrite(transport_ptr: *Transport, io: std.Io, data: []const u8) anyerror!void {
        const ep: *Endpoint = @fieldParentPtr("transport", transport_ptr);
        const duped = try ep.allocator.dupe(u8, data);
        errdefer ep.allocator.free(duped);
        ep.outbound.queue.putOne(io, duped) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return error.ConnectionClosed,
        };
    }

    fn endpointClose(transport_ptr: *Transport, io: std.Io) void {
        const ep: *Endpoint = @fieldParentPtr("transport", transport_ptr);
        ep.outbound.queue.close(io);
    }
};

test "BufferedTransport basic" {
    var transport_obj = BufferedTransport.init(std.testing.allocator);
    defer transport_obj.deinit();

    try transport_obj.setInput("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}\n");

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{
        .stack_size = 1024 * 1024,
        .argv0 = std.Io.Threaded.Argv0.empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const msg = try transport_obj.asTransport().read(io, std.testing.allocator);
    defer {
        if (msg) |m| {
            jsonrpc.Message.freeMessage(std.testing.allocator, m);
        }
    }

    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .notification);
    try std.testing.expectEqualStrings("test", msg.?.notification.method);
}

test "StdioTransport reads and writes with injected files" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{
        .stack_size = 1024 * 1024,
        .argv0 = std.Io.Threaded.Argv0.empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "in.jsonl",
        .data = "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}\n",
    });

    const in_file = try tmp_dir.dir.openFile(io, "in.jsonl", .{ .mode = .read_only });
    defer in_file.close(io);
    const out_file = try tmp_dir.dir.createFile(io, "out.jsonl", .{ .read = true, .truncate = true });
    defer out_file.close(io);

    var stdio = StdioTransport.initWithFiles(std.testing.allocator, in_file, out_file);
    defer stdio.deinit();

    const msg = (try stdio.asTransport().read(io, std.testing.allocator)) orelse return error.TestUnexpectedResult;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("test", msg.notification.method);

    try stdio.asTransport().write(io, "{\"jsonrpc\":\"2.0\",\"method\":\"out\"}");

    const st = try out_file.stat(io);
    const buf = try std.testing.allocator.alloc(u8, st.size);
    defer std.testing.allocator.free(buf);
    const n = try out_file.readPositionalAll(io, buf, 0);
    try std.testing.expectEqual(st.size, n);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"out\"}\n", buf);
}
