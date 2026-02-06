const std = @import("std");
const json = std.json;
const izo = @import("izomorph");
const jsonrpc = @import("jsonrpc.zig");
const types = @import("types.zig");
const transport_mod = @import("transport.zig");
const pending_mod = @import("pending_registry.zig");
const typed_codec = @import("serde/typed_codec.zig");
const Io = std.Io;

pub const Transport = transport_mod.Transport;

pub const ClientOptions = struct {
    name: []const u8,
    version: []const u8,
    capabilities: types.ClientCapabilities = .{},
    /// Default timeout for outbound requests initiated by this client.
    /// If null, requests wait indefinitely unless a per-call timeout is provided.
    default_timeout: ?std.Io.Clock.Duration = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    options: ClientOptions,
    transport: *Transport,
    next_request_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    server_capabilities: ?types.ServerCapabilities = null,
    server_info: ?types.Implementation = null,
    negotiated_version: ?[]const u8 = null,
    server_instructions: ?[]const u8 = null,
    server_info_owned: bool = false,
    negotiated_version_owned: bool = false,
    server_instructions_owned: bool = false,
    roots: std.ArrayList(types.Root) = .empty,

    ts_allocator: std.heap.ThreadSafeAllocator,
    io: ?std.Io = null,
    io_mutex: std.Io.Mutex = .init,

    inbound_queue: std.Io.Queue(*jsonrpc.Message) = undefined,
    inbound_buf: [128]*jsonrpc.Message = undefined,
    run_group: std.Io.Group = .init,

    pending: pending_mod.PendingRegistry = undefined,
    pending_inited: bool = false,
    run_error_mutex: std.Thread.Mutex = .{},
    run_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions, transport: *Transport) Client {
        return .{
            .allocator = allocator,
            .options = options,
            .transport = transport,
            .ts_allocator = .{ .child_allocator = allocator },
        };
    }

    pub fn deinit(self: *Client) void {
        for (self.roots.items) |r| {
            types.freeRoot(self.allocator, r);
        }
        self.roots.deinit(self.allocator);
        self.clearServerState();
        if (self.pending_inited) self.pending.deinit();
    }

    fn getAllocator(self: *Client) std.mem.Allocator {
        return (&self.ts_allocator).allocator();
    }

    pub fn run(self: *Client, io: std.Io) anyerror!void {
        self.io = io;
        if (!self.pending_inited) {
            self.pending = pending_mod.PendingRegistry.init(self.getAllocator());
            self.pending_inited = true;
        }
        self.run_error_mutex.lock();
        self.run_error = null;
        self.run_error_mutex.unlock();

        self.inbound_queue = std.Io.Queue(*jsonrpc.Message).init(self.inbound_buf[0..]);
        self.run_group = .init;

        try self.run_group.concurrent(io, readerMain, .{ self });
        try self.run_group.concurrent(io, dispatcherMain, .{ self });

        try self.run_group.await(io);

        self.run_error_mutex.lock();
        const err = self.run_error;
        self.run_error_mutex.unlock();
        if (err) |e| return e;
    }

    fn setRunError(self: *Client, err: anyerror) void {
        self.run_error_mutex.lock();
        defer self.run_error_mutex.unlock();
        if (self.run_error == null) self.run_error = err;
    }

    fn readerMain(self: *Client) void {
        const io = self.io orelse return;
        const a = self.getAllocator();

        while (true) {
            const msg_opt = self.transport.read(io, a) catch |err| {
                self.pending.notifyConnectionClosed(io);
                self.inbound_queue.close(io);
                self.setRunError(err);
                return;
            };
            var msg = msg_opt orelse {
                self.pending.notifyConnectionClosed(io);
                self.inbound_queue.close(io);
                return;
            };

            switch (msg) {
                .response => |*resp| {
                    const id = pending_mod.PendingRegistry.borrowedIdFromRequestId(resp.id);
                    const result = resp.result;
                    resp.result = .null;
                    self.pending.fulfillResult(io, id, result);
                    jsonrpc.Message.freeMessage(a, msg);
                },
                .@"error" => |*err_resp| {
                    if (err_resp.id) |rid| {
                        const id = pending_mod.PendingRegistry.borrowedIdFromRequestId(rid);
                        self.pending.fulfillFailed(io, id);
                    }
                    jsonrpc.Message.freeMessage(a, msg);
                },
                .request => {
                    const msg_ptr = a.create(jsonrpc.Message) catch |err| {
                        jsonrpc.Message.freeMessage(a, msg);
                        self.pending.notifyConnectionClosed(io);
                        self.inbound_queue.close(io);
                        self.setRunError(err);
                        return;
                    };
                    msg_ptr.* = msg;
                    self.inbound_queue.putOne(io, msg_ptr) catch |err| switch (err) {
                        error.Closed, error.Canceled => {
                            jsonrpc.Message.freeMessage(a, msg_ptr.*);
                            a.destroy(msg_ptr);
                            return;
                        },
                    };
                },
                .notification => {
                    // Client ignores notifications by default.
                    jsonrpc.Message.freeMessage(a, msg);
                },
            }
        }
    }

    fn dispatcherMain(self: *Client) void {
        const io = self.io orelse return;
        const a = self.getAllocator();

        while (true) {
            const msg_ptr = self.inbound_queue.getOne(io) catch |err| switch (err) {
                error.Closed, error.Canceled => return,
            };
            defer a.destroy(msg_ptr);

            switch (msg_ptr.*) {
                .request => |req| {
                    self.handleIncomingRequest(req) catch |err| {
                        // Can't respond safely if transport is failing; record and stop.
                        self.setRunError(err);
                        self.pending.notifyConnectionClosed(io);
                        self.inbound_queue.close(io);
                        jsonrpc.Message.freeMessage(a, msg_ptr.*);
                        return;
                    };
                },
                else => {},
            }
            jsonrpc.Message.freeMessage(a, msg_ptr.*);
        }
    }

    pub fn initialize(self: *Client) !types.InitializeResult {
        const params = .{
            .protocolVersion = types.LATEST_PROTOCOL_VERSION,
            .capabilities = self.options.capabilities,
            .clientInfo = types.Implementation{
                .name = self.options.name,
                .version = self.options.version,
            },
        };

        const wire_result = try self.requestTyped(
            WireInitializeResult,
            WireInitializeResultMapper,
            "initialize",
            params,
            null,
        );
        const result = wireInitializeToPublic(wire_result);
        self.setServerStateFromInitializeResult(result);

        try self.sendInitializedNotification();

        return result;
    }

    fn sendInitializedNotification(self: *Client) !void {
        try self.sendNotificationRaw("notifications/initialized", null);
    }

    pub fn ping(self: *Client) !void {
        const result = try self.requestRaw("ping", null, null);
        defer jsonrpc.Message.freeValue(self.getAllocator(), result);
    }

    pub fn newNumericId(self: *Client) jsonrpc.RequestId {
        return .{ .number = self.next_request_id.fetchAdd(1, .monotonic) };
    }

    /// Sends a JSON-RPC request to the server.
    /// If `timeout` is null, uses `options.default_timeout`.
    fn requestRaw(self: *Client, method: []const u8, params: anytype, timeout: ?Io.Clock.Duration) !json.Value {
        const id = self.newNumericId();
        return self.sendRequestWithIdTimeout(id, method, params, timeout);
    }

    pub fn requestTyped(
        self: *Client,
        comptime Resp: type,
        comptime RespMapper: type,
        method: []const u8,
        params: anytype,
        timeout: ?Io.Clock.Duration,
    ) !Resp {
        const result_value = try self.requestRaw(method, params, timeout);
        defer jsonrpc.Message.freeValue(self.getAllocator(), result_value);
        return try typed_codec.valueToTyped(self.allocator, Resp, RespMapper, result_value);
    }

    pub fn requestTypedDefault(
        self: *Client,
        comptime Resp: type,
        method: []const u8,
        params: anytype,
        timeout: ?Io.Clock.Duration,
    ) !Resp {
        return try self.requestTyped(Resp, typed_codec.defaultMapper(Resp), method, params, timeout);
    }

    pub fn callToolTyped(
        self: *Client,
        comptime Args: type,
        comptime Resp: type,
        comptime ArgsMapper: type,
        comptime RespMapper: type,
        name: []const u8,
        arguments: ?Args,
        timeout: ?Io.Clock.Duration,
    ) !Resp {
        const params = struct {
            name: []const u8,
            arguments: ?Args = null,
        }{
            .name = name,
            .arguments = arguments,
        };
        _ = ArgsMapper; // currently kept for parity with typed tool registration APIs.
        return try self.requestTyped(Resp, RespMapper, "tools/call", params, timeout);
    }

    fn effectiveTimeout(self: *Client, timeout: ?Io.Clock.Duration) ?Io.Clock.Duration {
        return timeout orelse self.options.default_timeout;
    }

    fn sendCancelledNotification(self: *Client, id: jsonrpc.RequestId) void {
        const io = self.io orelse return;
        var aw: Io.Writer.Allocating = .init(self.getAllocator());
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        jws.beginObject() catch return;
        jws.objectField("jsonrpc") catch return;
        jws.write("2.0") catch return;
        jws.objectField("method") catch return;
        jws.write("notifications/cancelled") catch return;
        jws.objectField("params") catch return;
        jws.beginObject() catch return;
        jws.objectField("requestId") catch return;
        id.jsonStringify(&jws) catch return;
        jws.endObject() catch return;
        jws.endObject() catch return;

        aw.writer.flush() catch return;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        _ = self.transport.write(io, aw.written()) catch {};
    }

    fn waitSharedPending(sp: *pending_mod.PendingRegistry.SharedPending, io: Io) (std.Io.QueueClosedError || std.Io.Cancelable)!pending_mod.PendingRegistry.Outcome {
        return sp.pending.wait(io);
    }

    fn sleepDuration(d: Io.Clock.Duration, io: Io) Io.SleepError!void {
        return d.sleep(io);
    }

    fn sendRequestWithIdTimeout(self: *Client, id: jsonrpc.RequestId, method: []const u8, params: anytype, timeout: ?Io.Clock.Duration) !json.Value {
        const io = self.io orelse return error.IoNotSet;
        const a = self.getAllocator();
        if (!self.pending_inited) {
            self.pending = pending_mod.PendingRegistry.init(a);
            self.pending_inited = true;
        }
        const borrowed_id = pending_mod.PendingRegistry.borrowedIdFromRequestId(id);
        const shared = try self.pending.register(io, borrowed_id);
        defer shared.release(a, io);
        errdefer self.pending.abandon(io, borrowed_id);

        var aw: Io.Writer.Allocating = .init(a);
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write("2.0");
        try jws.objectField("id");
        try id.jsonStringify(&jws);
        try jws.objectField("method");
        try jws.write(method);
        if (@TypeOf(params) != @TypeOf(null)) {
            try jws.objectField("params");
            try serializeParams(&jws, params);
        }
        try jws.endObject();

        try aw.writer.flush();
        self.io_mutex.lockUncancelable(io);
        {
            defer self.io_mutex.unlock(io);
            try self.transport.write(io, aw.written());
        }

        const eff_timeout = self.effectiveTimeout(timeout);
        const outcome = if (eff_timeout) |t| blk: {
            var wait_future = try Io.concurrent(io, waitSharedPending, .{ shared, io });
            errdefer {
                _ = wait_future.cancel(io) catch {};
            }
            var sleep_future = try Io.concurrent(io, sleepDuration, .{ t, io });
            errdefer {
                _ = sleep_future.cancel(io) catch {};
            }

            const selected = try Io.select(io, .{ .resp = &wait_future, .timeout = &sleep_future });
            switch (selected) {
                .resp => |res| {
                    _ = sleep_future.cancel(io) catch {};
                    break :blk try res;
                },
                .timeout => |sleep_res| {
                    // Propagate sleep errors (e.g. UnsupportedClock / Canceled) if any.
                    try sleep_res;
                    const wait_res = wait_future.cancel(io);
                    if (wait_res) |o| {
                        break :blk o;
                    } else |err| switch (err) {
                        error.Canceled => {
                            self.sendCancelledNotification(id);
                            return error.RequestTimeout;
                        },
                        error.Closed => return error.ConnectionClosed,
                    }
                },
            }
        } else blk: {
            break :blk try shared.pending.wait(io);
        };

        return switch (outcome) {
            .result => |v| v,
            .failed => error.RequestFailed,
            .connection_closed => error.ConnectionClosed,
        };
    }

    /// Replaces the client's roots list (deep-copies strings).
    /// If the client advertised `roots.listChanged` and is already initialized, sends `notifications/roots/list_changed`.
    pub fn setRoots(self: *Client, roots: []const types.Root) !void {
        for (self.roots.items) |r| {
            types.freeRoot(self.allocator, r);
        }
        self.roots.clearRetainingCapacity();

        for (roots) |r| {
            const uri_duped = try self.allocator.dupe(u8, r.uri);
            errdefer self.allocator.free(uri_duped);

            const name_duped = if (r.name) |n| blk: {
                const d = try self.allocator.dupe(u8, n);
                break :blk d;
            } else null;
            errdefer if (name_duped) |n| self.allocator.free(n);

            try self.roots.append(self.allocator, .{ .uri = uri_duped, .name = name_duped });
        }

        const roots_cap = self.options.capabilities.roots orelse return;
        if (!roots_cap.list_changed) return;
        if (self.negotiated_version == null) return;
        try self.sendRootsListChanged();
    }

    fn serializeParams(jws: *json.Stringify, params: anytype) !void {
        const T = @TypeOf(params);
        if (T == json.Value) {
            try jws.write(params);
        } else if (@typeInfo(T) == .optional) {
            if (params) |p| {
                try serializeParams(jws, p);
            } else {
                try jws.write(null);
            }
        } else if (@typeInfo(T) == .@"struct") {
            try jws.beginObject();
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const field_value = @field(params, field.name);
                const FieldType = @TypeOf(field_value);
                if (@typeInfo(FieldType) == .optional) {
                    if (field_value != null) {
                        try jws.objectField(field.name);
                        try serializeWithJsonStringify(jws, field_value.?);
                    }
                } else {
                    try jws.objectField(field.name);
                    try serializeWithJsonStringify(jws, field_value);
                }
            }
            try jws.endObject();
        } else {
            try jws.write(params);
        }
    }

    fn serializeWithJsonStringify(jws: *json.Stringify, value: anytype) !void {
        const T = @TypeOf(value);
        const is_container = switch (@typeInfo(T)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => true,
            else => false,
        };
        if (is_container and @hasDecl(T, "jsonStringify")) {
            try value.jsonStringify(jws);
        } else {
            try jws.write(value);
        }
    }

    // waitForResponse removed: Client uses a single reader + pending registry.

    fn handleIncomingRequest(self: *Client, req: jsonrpc.Request) !void {
        if (std.mem.eql(u8, req.method, "roots/list")) {
            if (self.options.capabilities.roots == null) {
                try self.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
                return;
            }
            if (req.params) |p| {
                if (p != .null) {
                    try self.sendError(jsonrpc.Error.invalidParams(req.id, "roots/list takes no params"));
                    return;
                }
            }
            const result = types.ListRootsResult{ .roots = self.roots.items };
            try self.sendResult(req.id, result);
            return;
        }

        try self.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
    }

    fn sendNotificationRaw(self: *Client, method: []const u8, params: ?json.Value) !void {
        const io = self.io orelse return error.IoNotSet;
        var aw: Io.Writer.Allocating = .init(self.getAllocator());
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write("2.0");
        try jws.objectField("method");
        try jws.write(method);
        if (params) |p| {
            try jws.objectField("params");
            try jws.write(p);
        }
        try jws.endObject();

        try aw.writer.flush();
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        try self.transport.write(io, aw.written());
    }

    pub fn sendRootsListChanged(self: *Client) !void {
        const roots_cap = self.options.capabilities.roots orelse return;
        if (!roots_cap.list_changed) return;
        try self.sendNotificationRaw("notifications/roots/list_changed", null);
    }

    fn sendResult(self: *Client, id: jsonrpc.RequestId, result: anytype) !void {
        const io = self.io orelse return error.IoNotSet;
        var aw: Io.Writer.Allocating = .init(self.getAllocator());
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write("2.0");
        try jws.objectField("id");
        try id.jsonStringify(&jws);
        try jws.objectField("result");
        try result.jsonStringify(&jws);
        try jws.endObject();

        try aw.writer.flush();
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        try self.transport.write(io, aw.written());
    }

    fn sendError(self: *Client, err: jsonrpc.Error) !void {
        const io = self.io orelse return error.IoNotSet;
        var aw: Io.Writer.Allocating = .init(self.getAllocator());
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try err.jsonStringify(&jws);

        try aw.writer.flush();
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        try self.transport.write(io, aw.written());
    }

    fn clearServerState(self: *Client) void {
        if (self.negotiated_version_owned and self.negotiated_version != null) {
            self.allocator.free(@constCast(self.negotiated_version.?));
        }
        self.negotiated_version = null;
        self.negotiated_version_owned = false;

        if (self.server_instructions_owned and self.server_instructions != null) {
            self.allocator.free(@constCast(self.server_instructions.?));
        }
        self.server_instructions = null;
        self.server_instructions_owned = false;

        if (self.server_info_owned and self.server_info != null) {
            freeImplementation(self.allocator, self.server_info.?);
        }
        self.server_info = null;
        self.server_info_owned = false;

        self.server_capabilities = null;
    }

    fn setServerStateFromInitializeResult(self: *Client, result: types.InitializeResult) void {
        self.clearServerState();
        self.server_capabilities = result.capabilities;
        self.server_info = result.serverInfo;
        self.server_info_owned = true;
        self.negotiated_version = result.protocolVersion;
        self.negotiated_version_owned = true;
        self.server_instructions = result.instructions;
        self.server_instructions_owned = result.instructions != null;
    }
};

const WirePromptsCapability = struct {
    listChanged: bool = false,
};

const WireResourcesCapability = struct {
    subscribe: bool = false,
    listChanged: bool = false,
};

const WireToolsCapability = struct {
    listChanged: bool = false,
};

const WireServerCapabilities = struct {
    prompts: ?WirePromptsCapability = null,
    resources: ?WireResourcesCapability = null,
    tools: ?WireToolsCapability = null,
    logging: ?struct {} = null,
    completions: ?struct {} = null,
};

const WireInitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: WireServerCapabilities,
    serverInfo: types.Implementation,
    instructions: ?[]const u8 = null,
};

const WireInitializeResultMapper = izo.Mapper(WireInitializeResult, .{});

fn wireInitializeToPublic(wire: WireInitializeResult) types.InitializeResult {
    return .{
        .protocolVersion = wire.protocolVersion,
        .capabilities = .{
            .prompts = if (wire.capabilities.prompts) |p| .{ .list_changed = p.listChanged } else null,
            .resources = if (wire.capabilities.resources) |r| .{
                .subscribe = r.subscribe,
                .list_changed = r.listChanged,
            } else null,
            .tools = if (wire.capabilities.tools) |t| .{ .list_changed = t.listChanged } else null,
            .logging = if (wire.capabilities.logging != null) .{} else null,
            .completions = if (wire.capabilities.completions != null) .{} else null,
        },
        .serverInfo = wire.serverInfo,
        .instructions = wire.instructions,
    };
}

fn freeImplementation(allocator: std.mem.Allocator, impl: types.Implementation) void {
    allocator.free(@constCast(impl.name));
    allocator.free(@constCast(impl.version));
    if (impl.title) |t| allocator.free(@constCast(t));
    if (impl.description) |d| allocator.free(@constCast(d));
}

const TestIo = struct {
    threaded: std.Io.Threaded,
    io: std.Io,

    pub fn init(self: *TestIo, allocator: std.mem.Allocator) void {
        self.threaded = std.Io.Threaded.init(allocator, .{
            .stack_size = 1024 * 1024,
            .argv0 = std.Io.Threaded.Argv0.empty,
            .environ = std.process.Environ.empty,
        });
        self.io = self.threaded.io();
    }

    pub fn deinit(self: *TestIo) void {
        self.threaded.deinit();
        self.* = undefined;
    }
};

test "Client init" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    _ = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var client = Client.init(
        std.testing.allocator,
        .{ .name = "test-client", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer client.deinit();

    try std.testing.expectEqualStrings("test-client", client.options.name);
}

test "Client initialize parses server result" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var duplex: transport_mod.DuplexTransport = undefined;
    duplex.init(std.testing.allocator);
    defer duplex.deinit(io);

    var client = Client.init(
        std.testing.allocator,
        .{ .name = "test-client", .version = "1.0.0" },
        duplex.endpointA().asTransport(),
    );
    defer client.deinit();
    client.io = io;

    const FakeServer = struct {
        fn run(ep: *transport_mod.DuplexTransport.Endpoint, io2: std.Io) !void {
            const msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

            const req = switch (msg) {
                .request => |r| r,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqualStrings("initialize", req.method);
            const id_num = switch (req.id) {
                .number => |n| n,
                .string => return error.UnexpectedToken,
            };

            const response = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{\"subscribe\":true}}}},\"serverInfo\":{{\"name\":\"srv\",\"version\":\"1.2.3\",\"title\":\"T\"}},\"instructions\":\"hi\"}}}}",
                .{id_num},
            );
            defer std.testing.allocator.free(response);
            try ep.asTransport().write(io2, response);

            // Read notifications/initialized.
            const notif_msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, notif_msg);
            try std.testing.expect(notif_msg == .notification);
            try std.testing.expectEqualStrings("notifications/initialized", notif_msg.notification.method);

            ep.asTransport().close(io2);
        }
    };

    var run_future = try std.Io.concurrent(io, Client.run, .{ &client, io });
    var srv_future = try std.Io.concurrent(io, FakeServer.run, .{ duplex.endpointB(), io });

    const result = try client.initialize();

    try srv_future.await(io);
    try run_future.await(io);

    try std.testing.expectEqualStrings("2025-03-26", result.protocolVersion);
    try std.testing.expectEqualStrings("srv", result.serverInfo.name);
    try std.testing.expectEqualStrings("1.2.3", result.serverInfo.version);
    try std.testing.expect(result.serverInfo.title != null);
    try std.testing.expectEqualStrings("T", result.serverInfo.title.?);
    try std.testing.expect(result.instructions != null);
    try std.testing.expectEqualStrings("hi", result.instructions.?);
    try std.testing.expect(result.capabilities.tools != null);
    try std.testing.expect(result.capabilities.resources != null);

    // FakeServer validated that initialize request and initialized notification were sent.
}

test "Client initialize sends roots capability with listChanged" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var duplex: transport_mod.DuplexTransport = undefined;
    duplex.init(std.testing.allocator);
    defer duplex.deinit(io);

    var client = Client.init(
        std.testing.allocator,
        .{
            .name = "test-client",
            .version = "1.0.0",
            .capabilities = .{ .roots = .{ .list_changed = true } },
        },
        duplex.endpointA().asTransport(),
    );
    defer client.deinit();
    client.io = io;

    const FakeServer = struct {
        fn run(ep: *transport_mod.DuplexTransport.Endpoint, io2: std.Io) !void {
            const msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

            const req = switch (msg) {
                .request => |r| r,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqualStrings("initialize", req.method);
            const id_num = switch (req.id) {
                .number => |n| n,
                .string => return error.UnexpectedToken,
            };

            // Validate roots.listChanged in params.capabilities.
            const params = req.params orelse return error.UnexpectedToken;
            const obj = switch (params) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            const caps_val = obj.get("capabilities") orelse return error.UnexpectedToken;
            const caps_obj = switch (caps_val) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            const roots_val = caps_obj.get("roots") orelse return error.UnexpectedToken;
            const roots_obj = switch (roots_val) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            const lc = roots_obj.get("listChanged") orelse return error.UnexpectedToken;
            try std.testing.expect(lc == .bool and lc.bool);

            const response = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{{}},\"serverInfo\":{{\"name\":\"srv\",\"version\":\"1.2.3\"}}}}}}",
                .{id_num},
            );
            defer std.testing.allocator.free(response);
            try ep.asTransport().write(io2, response);

            // Read notifications/initialized.
            const initialized_msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, initialized_msg);
            ep.asTransport().close(io2);
        }
    };

    var run_future = try std.Io.concurrent(io, Client.run, .{ &client, io });
    var srv_future = try std.Io.concurrent(io, FakeServer.run, .{ duplex.endpointB(), io });

    _ = try client.initialize();

    try srv_future.await(io);
    try run_future.await(io);
}

test "Client responds to roots/list while waiting for response" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var duplex: transport_mod.DuplexTransport = undefined;
    duplex.init(std.testing.allocator);
    defer duplex.deinit(io);

    var client = Client.init(
        std.testing.allocator,
        .{
            .name = "test-client",
            .version = "1.0.0",
            .capabilities = .{ .roots = .{} },
        },
        duplex.endpointA().asTransport(),
    );
    defer client.deinit();
    client.io = io;

    try client.setRoots(&[_]types.Root{
        .{ .uri = "file:///repo", .name = "repo" },
        .{ .uri = "file:///tmp" },
    });

    const FakeServer = struct {
        fn run(ep: *transport_mod.DuplexTransport.Endpoint, io2: std.Io) !void {
            // Expect ping request.
            const ping_msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, ping_msg);
            const ping_req = switch (ping_msg) {
                .request => |r| r,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqualStrings("ping", ping_req.method);
            const ping_id = switch (ping_req.id) {
                .number => |n| n,
                .string => return error.UnexpectedToken,
            };

            // While client is waiting for ping response, ask it for roots/list.
            try ep.asTransport().write(io2, "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"roots/list\"}");

            // Expect roots/list response.
            const roots_resp_msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, roots_resp_msg);
            try std.testing.expect(roots_resp_msg == .response);
            try std.testing.expect(roots_resp_msg.response.id == .number);
            try std.testing.expectEqual(@as(i64, 99), roots_resp_msg.response.id.number);

            const obj = switch (roots_resp_msg.response.result) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            const roots_val = obj.get("roots") orelse return error.UnexpectedToken;
            const roots_arr = switch (roots_val) {
                .array => |a| a,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqual(@as(usize, 2), roots_arr.items.len);

            // Now respond to ping.
            const ping_resp = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}",
                .{ping_id},
            );
            defer std.testing.allocator.free(ping_resp);
            try ep.asTransport().write(io2, ping_resp);
            ep.asTransport().close(io2);
        }
    };

    var run_future = try std.Io.concurrent(io, Client.run, .{ &client, io });
    var srv_future = try std.Io.concurrent(io, FakeServer.run, .{ duplex.endpointB(), io });

    try client.ping();

    try srv_future.await(io);
    try run_future.await(io);
}

test "Client request timeout sends notifications/cancelled" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var duplex: transport_mod.DuplexTransport = undefined;
    duplex.init(std.testing.allocator);
    defer duplex.deinit(io);

    const timeout: Io.Clock.Duration = .{ .raw = Io.Duration.fromMilliseconds(10), .clock = .boot };

    var client = Client.init(
        std.testing.allocator,
        .{
            .name = "test-client",
            .version = "1.0.0",
            .capabilities = .{},
            .default_timeout = timeout,
        },
        duplex.endpointA().asTransport(),
    );
    defer client.deinit();
    client.io = io;

    const FakeServer = struct {
        fn run(ep: *transport_mod.DuplexTransport.Endpoint, io2: std.Io) !void {
            const ping_msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, ping_msg);
            const ping_req = switch (ping_msg) {
                .request => |r| r,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqualStrings("ping", ping_req.method);
            const ping_id = ping_req.id;

            const cancel_msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, cancel_msg);
            const notif = switch (cancel_msg) {
                .notification => |n| n,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqualStrings("notifications/cancelled", notif.method);
            const params = notif.params orelse return error.UnexpectedToken;
            const obj = switch (params) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            const rid_val = obj.get("requestId") orelse return error.UnexpectedToken;
            const rid: jsonrpc.RequestId = switch (rid_val) {
                .string => |s| .{ .string = s },
                .integer => |n| .{ .number = n },
                .number_string => |s| .{ .number = try std.fmt.parseInt(i64, s, 10) },
                else => return error.UnexpectedToken,
            };
            try std.testing.expect(ping_id.eql(rid));
            ep.asTransport().close(io2);
        }
    };

    var srv_future = try std.Io.concurrent(io, FakeServer.run, .{ duplex.endpointB(), io });

    try std.testing.expectError(error.RequestTimeout, client.ping());

    try srv_future.await(io);
}
