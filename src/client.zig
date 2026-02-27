const std = @import("std");
const json = std.json;
const izo = @import("izomorph");
const jsonrpc = @import("jsonrpc.zig");
const types = @import("types.zig");
const transport_mod = @import("transport.zig");
const pending_mod = @import("pending_registry.zig");
const typed_codec = @import("serde/typed_codec.zig");
const envelope_codec = @import("serde/envelope_codec.zig");
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

    ts_allocator: std.heap.ThreadSafeAllocator = undefined,
    ts_allocator_inited: bool = false,
    io: ?std.Io = null,
    io_mutex: std.Io.Mutex = .init,

    inbound_queue: std.Io.Queue(*jsonrpc.Message) = undefined,
    inbound_buf: [128]*jsonrpc.Message = undefined,
    run_group: std.Io.Group = .init,

    pending: pending_mod.PendingRegistry = undefined,
    pending_inited: bool = false,
    run_error_mutex: std.Io.Mutex = .init,
    run_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions, transport: *Transport) Client {
        return .{
            .allocator = allocator,
            .options = options,
            .transport = transport,
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
        if (!self.ts_allocator_inited) {
            // Return the raw allocator if ThreadSafeAllocator is not initialized yet
            return self.allocator;
        }
        return (&self.ts_allocator).allocator();
    }

    pub fn run(self: *Client, io: std.Io) anyerror!void {
        self.io = io;
        if (!self.ts_allocator_inited) {
            self.ts_allocator = .{ .child_allocator = self.allocator, .io = io };
            self.ts_allocator_inited = true;
        }
        if (!self.pending_inited) {
            self.pending = pending_mod.PendingRegistry.init(self.getAllocator());
            self.pending_inited = true;
        }
        self.run_error_mutex.lockUncancelable(io);
        self.run_error = null;
        self.run_error_mutex.unlock(io);

        self.inbound_queue = std.Io.Queue(*jsonrpc.Message).init(self.inbound_buf[0..]);
        self.run_group = .init;

        try self.run_group.concurrent(io, readerMain, .{self});
        try self.run_group.concurrent(io, dispatcherMain, .{self});

        try self.run_group.await(io);

        self.run_error_mutex.lockUncancelable(io);
        const err = self.run_error;
        self.run_error_mutex.unlock(io);
        if (err) |e| return e;
    }

    fn setRunError(self: *Client, err: anyerror) void {
        const io = self.io orelse return;
        self.run_error_mutex.lockUncancelable(io);
        defer self.run_error_mutex.unlock(io);
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
        const params = types.InitializeRequestParams{
            .protocolVersion = types.LATEST_PROTOCOL_VERSION,
            .capabilities = self.options.capabilities,
            .clientInfo = types.Implementation{
                .name = self.options.name,
                .version = self.options.version,
            },
        };

        const result_value = try self.requestRaw("initialize", params, null);
        defer jsonrpc.Message.freeValue(self.getAllocator(), result_value);

        // Parse result using std.json directly to avoid memory issues with izomorph
        const result = try parseInitializeResult(self.allocator, result_value);
        self.setServerStateFromInitializeResult(result);

        try self.sendInitializedNotification();

        return result;
    }

    fn sendInitializedNotification(self: *Client) !void {
        try self.sendNotification("notifications/initialized", null);
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

    /// Sends a typed JSON-RPC request to the server.
    /// REQUIRES: The caller must pass an arena allocator. The returned Resp may contain
    /// slices that point into arena-allocated memory and will be freed when the arena is deinitialized.
    pub fn requestTyped(
        self: *Client,
        arena: std.mem.Allocator,
        comptime Resp: type,
        comptime RespMapper: type,
        method: []const u8,
        params: anytype,
        timeout: ?Io.Clock.Duration,
    ) !Resp {
        const result_value = try self.requestRaw(method, params, timeout);
        defer jsonrpc.Message.freeValue(self.getAllocator(), result_value);
        return try typed_codec.valueToTyped(arena, Resp, RespMapper, result_value);
    }

    pub fn requestTypedDefault(
        self: *Client,
        arena: std.mem.Allocator,
        comptime Resp: type,
        method: []const u8,
        params: anytype,
        timeout: ?Io.Clock.Duration,
    ) !Resp {
        return try self.requestTyped(arena, Resp, typed_codec.defaultMapper(Resp), method, params, timeout);
    }

    pub fn callToolTyped(
        self: *Client,
        arena: std.mem.Allocator,
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
        return try self.requestTyped(arena, Resp, RespMapper, "tools/call", params, timeout);
    }

    fn effectiveTimeout(self: *Client, timeout: ?Io.Clock.Duration) ?Io.Clock.Duration {
        return timeout orelse self.options.default_timeout;
    }

    const CancelParams = struct {
        requestId: jsonrpc.RequestId,
        pub const Mapper = izo.Mapper(CancelParams, .{});
    };

    fn sendCancelledNotification(self: *Client, id: jsonrpc.RequestId) void {
        const io = self.io orelse return;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        const writer = self.transport.getWriter(io);
        envelope_codec.encodeNotificationToWriter(writer, "notifications/cancelled", CancelParams{ .requestId = id }) catch return;
        writer.writeByte('\n') catch {};
        writer.flush() catch {};
    }

    fn waitSharedPending(sp: *pending_mod.PendingRegistry.SharedPending, io: Io) (std.Io.QueueClosedError || std.Io.Cancelable)!pending_mod.PendingRegistry.Outcome {
        return sp.pending.wait(io);
    }

    fn sleepDuration(d: Io.Clock.Duration, io: Io) Io.Cancelable!void {
        return d.sleep(io);
    }

    fn sendRequestWithIdTimeout(self: *Client, id: jsonrpc.RequestId, method: []const u8, params: anytype, timeout: ?Io.Clock.Duration) !json.Value {
        const io = self.io orelse return error.IoNotSet;
        if (!self.pending_inited) {
            self.pending = pending_mod.PendingRegistry.init(self.getAllocator());
            self.pending_inited = true;
        }
        const borrowed_id = pending_mod.PendingRegistry.borrowedIdFromRequestId(id);
        const shared = try self.pending.register(io, borrowed_id);
        defer shared.release(self.getAllocator(), io);
        errdefer self.pending.abandon(io, borrowed_id);

        self.io_mutex.lockUncancelable(io);
        {
            defer self.io_mutex.unlock(io);
            const writer = self.transport.getWriter(io);
            try envelope_codec.encodeRequestToWriter(writer, id, method, params);
            try writer.writeByte('\n');
            try writer.flush();
        }

        const eff_timeout = self.effectiveTimeout(timeout);
        const outcome = if (eff_timeout) |t| blk: {
            // Manual race using a queue
            const RaceResult = union(enum) {
                wait: pending_mod.PendingRegistry.Outcome,
                timeout: void,
            };
            const RaceQueue = std.Io.Queue(RaceResult);
            var race_buf: [2]RaceResult = undefined;
            var race_q: RaceQueue = .init(race_buf[0..]);

            const WaitTask = struct {
                fn run(sp: *pending_mod.PendingRegistry.SharedPending, io_: Io, q: *RaceQueue) anyerror!void {
                    const outcome = try sp.pending.wait(io_);
                    q.putOneUncancelable(io_, .{ .wait = outcome }) catch {};
                }
            };
            const SleepTask = struct {
                fn run(d: Io.Clock.Duration, io_: Io, q: *RaceQueue) anyerror!void {
                    try d.sleep(io_);
                    q.putOneUncancelable(io_, .{ .timeout = {} }) catch {};
                }
            };

            var wait_future = try Io.concurrent(io, WaitTask.run, .{ shared, io, &race_q });
            errdefer _ = wait_future.cancel(io) catch {};
            var sleep_future = try Io.concurrent(io, SleepTask.run, .{ t, io, &race_q });
            errdefer _ = sleep_future.cancel(io) catch {};

            const selected = try race_q.getOne(io);
            switch (selected) {
                .wait => |outcome| {
                    _ = sleep_future.cancel(io) catch {};
                    break :blk outcome;
                },
                .timeout => {
                    _ = wait_future.cancel(io) catch {};
                    self.sendCancelledNotification(id);
                    return error.RequestTimeout;
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

    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        const io = self.io orelse return error.IoNotSet;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        const writer = self.transport.getWriter(io);
        try envelope_codec.encodeNotificationToWriter(writer, method, params);
        try writer.writeByte('\n');
        try writer.flush();
    }

    pub fn sendRootsListChanged(self: *Client) !void {
        const roots_cap = self.options.capabilities.roots orelse return;
        if (!roots_cap.list_changed) return;
        try self.sendNotification("notifications/roots/list_changed", null);
    }

    fn sendResult(self: *Client, id: jsonrpc.RequestId, result: anytype) !void {
        const io = self.io orelse return error.IoNotSet;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        const writer = self.transport.getWriter(io);
        try envelope_codec.encodeResponseToWriter(writer, id, result);
        try writer.writeByte('\n');
        try writer.flush();
    }

    fn sendError(self: *Client, err: jsonrpc.Error) !void {
        const io = self.io orelse return error.IoNotSet;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        const writer = self.transport.getWriter(io);
        try envelope_codec.encodeErrorToWriter(writer, err.id, err.@"error");
        try writer.writeByte('\n');
        try writer.flush();
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

fn parseInitializeResult(allocator: std.mem.Allocator, value: json.Value) !types.InitializeResult {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const protocolVersion = blk: {
        const pv = obj.get("protocolVersion") orelse return error.InvalidResponse;
        break :blk switch (pv) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidResponse,
        };
    };
    errdefer allocator.free(protocolVersion);

    const serverInfo = blk: {
        const si = obj.get("serverInfo") orelse return error.InvalidResponse;
        const si_obj = switch (si) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
        const name_val = si_obj.get("name") orelse return error.InvalidResponse;
        const name = switch (name_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidResponse,
        };
        errdefer allocator.free(name);
        const version_val = si_obj.get("version") orelse return error.InvalidResponse;
        const version = switch (version_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidResponse,
        };
        errdefer allocator.free(version);
        const title: ?[]u8 = if (si_obj.get("title")) |tv| switch (tv) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        } else null;
        errdefer if (title) |t| allocator.free(t);
        break :blk types.Implementation{
            .name = name,
            .version = version,
            .title = title,
        };
    };
    errdefer freeImplementation(allocator, serverInfo);

    const instructions: ?[]u8 = if (obj.get("instructions")) |iv| switch (iv) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    errdefer if (instructions) |i| allocator.free(i);

    // Parse capabilities
    var capabilities: types.ServerCapabilities = .{};
    if (obj.get("capabilities")) |caps_val| {
        if (caps_val == .object) {
            const caps_obj = caps_val.object;
            if (caps_obj.get("tools") != null) {
                capabilities.tools = .{};
            }
            if (caps_obj.get("resources")) |res_val| {
                if (res_val == .object) {
                    const res_obj = res_val.object;
                    capabilities.resources = .{
                        .subscribe = if (res_obj.get("subscribe")) |s| switch (s) {
                            .bool => |b| b,
                            else => false,
                        } else false,
                        .list_changed = if (res_obj.get("listChanged")) |lc| switch (lc) {
                            .bool => |b| b,
                            else => false,
                        } else false,
                    };
                }
            }
            if (caps_obj.get("prompts") != null) {
                capabilities.prompts = .{};
            }
            if (caps_obj.get("logging") != null) {
                capabilities.logging = .{};
            }
        }
    }

    return types.InitializeResult{
        .protocolVersion = protocolVersion,
        .capabilities = capabilities,
        .serverInfo = serverInfo,
        .instructions = instructions,
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
            defer ep.asTransport().close(io2);
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
        }
    };

    var run_future = try std.Io.concurrent(io, Client.run, .{ &client, io });
    defer _ = run_future.cancel(io) catch {};
    var srv_future = try std.Io.concurrent(io, FakeServer.run, .{ duplex.endpointB(), io });
    defer _ = srv_future.cancel(io) catch {};

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
