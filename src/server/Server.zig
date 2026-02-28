const std = @import("std");
const json = std.json;
const izo = @import("izomorph");
const jsonrpc = @import("../jsonrpc.zig");
const types = @import("../types.zig");
const transport_mod = @import("../transport.zig");
const common = @import("common.zig");
const cancellation_mod = @import("cancellation.zig");
const cascade_mod = @import("capabilities/Cascade.zig");
const pending_mod = @import("../pending_registry.zig");
const typed_codec = @import("../serde/typed_codec.zig");
const envelope_codec = @import("../serde/envelope_codec.zig");
const Io = std.Io;

pub const Transport = transport_mod.Transport;

pub const ToolCallMeta = common.ToolCallMeta;
pub const CancellationToken = common.CancellationToken;

pub const NotificationHandler = *const fn (
    user_data: ?*anyopaque,
    server: *Server,
    notif: jsonrpc.Notification,
) anyerror!void;

pub const ServerOptions = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    /// Enables MCP logging (`logging/*` and `notifications/message`).
    enable_logging: bool = true,
    /// Minimum log level used before a client requests `logging/setLevel`.
    default_log_level: types.LoggingLevel = .info,
    /// Default timeout for outbound requests initiated by this server.
    /// If null, requests wait indefinitely unless a per-call timeout is provided.
    default_timeout: ?std.Io.Clock.Duration = null,
    user_data: ?*anyopaque = null,
    on_notification: ?NotificationHandler = null,
    /// Enables MCP `tasks/*` and task-augmented `tools/call` requests.
    enable_tasks: bool = true,
    /// Number of worker threads used for task execution.
    task_workers: usize = 1,
};

pub const InitializationState = enum {
    not_initialized,
    initializing,
    initialized,
};

pub const Server = struct {
    pub const ActiveRequest = struct {
        id: jsonrpc.RequestId,
        cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    const WireClientRootsCapability = struct {
        listChanged: bool = false,
    };

    const WireClientCapabilities = struct {
        roots: ?WireClientRootsCapability = null,
        sampling: ?struct {} = null,
        elicitation: ?struct {} = null,
    };

    const WireInitializeRequestParams = struct {
        protocolVersion: ?[]const u8 = null,
        capabilities: ?WireClientCapabilities = null,
        clientInfo: ?types.Implementation = null,
    };

    const WireInitializeRequestParamsMapper = typed_codec.defaultMapper(WireInitializeRequestParams);

    allocator: std.mem.Allocator,
    options: ServerOptions,
    transport: *Transport,
    initialization_state: InitializationState = .not_initialized,
    client_capabilities: ?types.ClientCapabilities = null,
    client_info: ?types.Implementation = null,
    negotiated_version: []const u8 = types.DEFAULT_NEGOTIATED_VERSION,
    negotiated_version_owned: ?[]u8 = null,
    client_info_owned: bool = false,
    next_request_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    user_data: ?*anyopaque = null,
    on_notification: ?NotificationHandler = null,
    min_log_level: std.atomic.Value(u8),

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

    active_requests_mutex: std.Io.Mutex = .init,
    active_requests: std.ArrayList(*ActiveRequest) = .empty,

    capabilities: cascade_mod.Cascade,
    capabilities_attached: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions, transport: *Transport) Server {
        return .{
            .allocator = allocator,
            .options = options,
            .transport = transport,
            .user_data = options.user_data,
            .on_notification = options.on_notification,
            .min_log_level = std.atomic.Value(u8).init(@intFromEnum(options.default_log_level)),
            .capabilities = cascade_mod.Cascade.init(
                allocator,
                options.user_data,
                options.enable_tasks,
                options.task_workers,
            ),
        };
    }

    pub fn deinit(self: *Server) void {
        self.attachCapabilities();

        if (self.negotiated_version_owned) |v| self.allocator.free(v);
        if (self.client_info_owned) {
            if (self.client_info) |info| freeImplementation(self.allocator, info);
        }

        self.capabilities.deinit();

        self.active_requests.deinit(self.allocator);
        if (self.pending_inited) self.pending.deinit();
    }

    pub fn getAllocator(self: *Server) std.mem.Allocator {
        if (!self.ts_allocator_inited) {
            // Return the raw allocator if ThreadSafeAllocator is not initialized yet
            return self.allocator;
        }
        return (&self.ts_allocator).allocator();
    }

    fn attachCapabilities(self: *Server) void {
        if (self.capabilities_attached) return;

        self.capabilities.tasks.setWorkerAllocator(self.getAllocator());
        self.capabilities.tasks.setStatusNotifier(.{
            .ctx = @ptrCast(self),
            .send = notifyTaskStatus,
        });

        self.capabilities_attached = true;
    }

    fn notifyTaskStatus(ctx: *anyopaque, task: types.Task) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendNotification("notifications/tasks/status", task) catch {};
    }

    pub fn run(self: *Server, io: std.Io) anyerror!void {
        self.attachCapabilities();
        self.capabilities.tasks.setIo(io);

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

    fn setRunError(self: *Server, err: anyerror) void {
        const io = self.io orelse return;
        self.run_error_mutex.lockUncancelable(io);
        defer self.run_error_mutex.unlock(io);
        if (self.run_error == null) self.run_error = err;
    }

    fn readerMain(self: *Server) void {
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
                .request, .notification => {
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
            }
        }
    }

    fn dispatcherMain(self: *Server) void {
        const io = self.io orelse return;
        const a = self.getAllocator();

        while (true) {
            const msg_ptr = self.inbound_queue.getOne(io) catch |err| switch (err) {
                error.Closed, error.Canceled => return,
            };
            defer a.destroy(msg_ptr);

            self.handleMessage(io, msg_ptr.*) catch |err| {
                jsonrpc.Message.freeMessage(a, msg_ptr.*);
                self.setRunError(err);
                self.pending.notifyConnectionClosed(io);
                self.inbound_queue.close(io);
                return;
            };
            jsonrpc.Message.freeMessage(a, msg_ptr.*);
        }
    }

    /// Sends `roots/list` to the connected client and returns the client's current roots.
    /// Caller owns the returned value and must call `deinit()`.
    pub fn listRoots(self: *Server) !types.OwnedListRootsResult {
        return try self.listRootsWithTimeout(null);
    }

    /// Like `listRoots` but allows overriding the timeout for this call.
    pub fn listRootsWithTimeout(self: *Server, timeout: ?Io.Clock.Duration) !types.OwnedListRootsResult {
        const result_value = try self.requestClient("roots/list", null, timeout);
        defer jsonrpc.Message.freeValue(self.getAllocator(), result_value);

        // Parse result directly from json.Value
        return try parseListRootsResult(self.allocator, result_value);
    }

    fn parseListRootsResult(allocator: std.mem.Allocator, value: json.Value) !types.OwnedListRootsResult {
        const obj = switch (value) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };

        var result = types.OwnedListRootsResult.init(allocator);
        errdefer result.deinit();

        const roots_val = obj.get("roots") orelse return error.InvalidResponse;
        const roots_arr = switch (roots_val) {
            .array => |a| a,
            else => return error.InvalidResponse,
        };

        for (roots_arr.items) |root_val| {
            const root_obj = switch (root_val) {
                .object => |o| o,
                else => continue,
            };

            const uri_val = root_obj.get("uri") orelse continue;
            const uri = switch (uri_val) {
                .string => |s| s,
                else => continue,
            };

            const name: ?[]const u8 = if (root_obj.get("name")) |nv| switch (nv) {
                .string => |s| s,
                else => null,
            } else null;

            try result.addRoot(uri, name);
        }

        return result;
    }

    pub fn handleMessage(self: *Server, io: std.Io, msg: jsonrpc.Message) !void {
        self.attachCapabilities();
        switch (msg) {
            .request => |req| try self.handleRequest(req),
            .notification => |notif| try self.handleNotification(io, notif),
            .response => {},
            .@"error" => {},
        }
    }

    fn handleRequest(self: *Server, req: jsonrpc.Request) !void {
        if (std.mem.eql(u8, req.method, "initialize")) {
            try self.handleInitialize(req);
        } else if (std.mem.eql(u8, req.method, "ping")) {
            try self.handlePing(req);
        } else if (std.mem.eql(u8, req.method, "logging/setLevel")) {
            try self.handleLoggingSetLevel(req);
        } else if (try self.capabilities.handleRequest(self, req)) {
            // handled by a capability
        } else {
            try self.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
        }
    }

    fn handleNotification(self: *Server, io: std.Io, notif: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notif.method, "notifications/initialized")) {
            self.initialization_state = .initialized;
        } else if (std.mem.eql(u8, notif.method, "notifications/cancelled")) {
            cancellation_mod.handleCancelledNotification(self, io, notif);
        } else if (std.mem.eql(u8, notif.method, "notifications/roots/list_changed")) {
            // Client roots changed; callers can re-fetch via `roots/list`.
        }

        try self.capabilities.handleNotification(self, notif);

        if (self.on_notification) |cb| {
            try cb(self.user_data, self, notif);
        }
    }

    pub fn isInitialized(self: *Server) bool {
        return self.initialization_state == .initialized;
    }

    fn handleInitialize(self: *Server, req: jsonrpc.Request) !void {
        self.initialization_state = .initializing;

        if (req.params) |params| {
            if (params == .object) {
                const obj = params.object;

                // Parse protocolVersion
                if (obj.get("protocolVersion")) |pv_val| {
                    if (pv_val == .string) {
                        const pv = try self.allocator.dupe(u8, pv_val.string);
                        if (self.negotiated_version_owned) |v| self.allocator.free(v);
                        self.negotiated_version_owned = pv;
                        self.negotiated_version = pv;
                    }
                }

                // Parse clientInfo
                if (obj.get("clientInfo")) |ci_val| {
                    if (ci_val == .object) {
                        const ci_obj = ci_val.object;
                        if (ci_obj.get("name")) |name_val| {
                            if (ci_obj.get("version")) |version_val| {
                                if (name_val == .string and version_val == .string) {
                                    if (self.client_info_owned) {
                                        if (self.client_info) |old| freeImplementation(self.allocator, old);
                                    }
                                    const name = try self.allocator.dupe(u8, name_val.string);
                                    errdefer self.allocator.free(name);
                                    const version = try self.allocator.dupe(u8, version_val.string);
                                    errdefer self.allocator.free(version);
                                    const title: ?[]u8 = if (ci_obj.get("title")) |tv| switch (tv) {
                                        .string => |s| try self.allocator.dupe(u8, s),
                                        else => null,
                                    } else null;
                                    errdefer if (title) |t| self.allocator.free(t);
                                    self.client_info = .{
                                        .name = name,
                                        .version = version,
                                        .title = title,
                                    };
                                    self.client_info_owned = true;
                                }
                            }
                        }
                    }
                }

                // Parse capabilities
                if (obj.get("capabilities")) |caps_val| {
                    if (caps_val == .object) {
                        const caps_obj = caps_val.object;
                        var caps: types.ClientCapabilities = .{};
                        if (caps_obj.get("roots")) |roots_val| {
                            if (roots_val == .object) {
                                const roots_obj = roots_val.object;
                                caps.roots = .{
                                    .list_changed = if (roots_obj.get("listChanged")) |lc| switch (lc) {
                                        .bool => |b| b,
                                        else => false,
                                    } else false,
                                };
                            }
                        }
                        if (caps_obj.get("sampling") != null) {
                            caps.sampling = .{};
                        }
                        if (caps_obj.get("elicitation") != null) {
                            caps.elicitation = .{};
                        }
                        self.client_capabilities = caps;
                    }
                }
            }
        }

        const result = types.InitializeResult{
            .protocolVersion = self.negotiated_version,
            .capabilities = self.getCapabilities(),
            .serverInfo = .{
                .name = self.options.name,
                .version = self.options.version,
                .title = self.options.title,
                .description = self.options.description,
            },
            .instructions = self.options.instructions,
        };

        try self.sendResult(req.id, result);
    }

    const WireRoot = struct {
        uri: []const u8,
        name: ?[]const u8 = null,
    };

    const WireListRootsResult = struct {
        roots: []const WireRoot,
    };

    const WireListRootsResultMapper = typed_codec.defaultMapper(WireListRootsResult);

    fn ownedRootsFromWire(allocator: std.mem.Allocator, roots: []const WireRoot) !types.OwnedListRootsResult {
        var result = types.OwnedListRootsResult.init(allocator);
        errdefer result.deinit();
        for (roots) |r| {
            try result.addRoot(r.uri, r.name);
        }
        return result;
    }

    pub fn newNumericId(self: *Server) jsonrpc.RequestId {
        return .{ .number = self.next_request_id.fetchAdd(1, .monotonic) };
    }

    fn sendRequest(self: *Server, method: []const u8, params: anytype) !json.Value {
        const id = self.newNumericId();
        return self.sendRequestWithIdTimeout(id, method, params, null);
    }

    fn effectiveTimeout(self: *Server, timeout: ?Io.Clock.Duration) ?Io.Clock.Duration {
        return timeout orelse self.options.default_timeout;
    }

    /// Sends a JSON-RPC request to the connected client.
    /// If `timeout` is null, uses `options.default_timeout`.
    pub fn requestClient(self: *Server, method: []const u8, params: anytype, timeout: ?Io.Clock.Duration) !json.Value {
        const id = self.newNumericId();
        return self.sendRequestWithIdTimeout(id, method, params, timeout);
    }

    /// Sends a typed JSON-RPC request to the connected client.
    /// REQUIRES: The caller must pass an arena allocator. The returned Resp may contain
    /// slices that point into arena-allocated memory and will be freed when the arena is deinitialized.
    pub fn requestClientTyped(
        self: *Server,
        arena: std.mem.Allocator,
        comptime Resp: type,
        comptime RespMapper: type,
        method: []const u8,
        params: anytype,
        timeout: ?Io.Clock.Duration,
    ) !Resp {
        const result_value = try self.requestClient(method, params, timeout);
        defer jsonrpc.Message.freeValue(self.getAllocator(), result_value);
        return try typed_codec.valueToTyped(arena, Resp, RespMapper, result_value);
    }

    const CancelParams = struct {
        requestId: jsonrpc.RequestId,
        pub const Mapper = izo.Mapper(CancelParams, .{});
    };

    fn sendCancelledNotification(self: *Server, id: jsonrpc.RequestId) void {
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

    fn sendRequestWithIdTimeout(self: *Server, id: jsonrpc.RequestId, method: []const u8, params: anytype, timeout: ?Io.Clock.Duration) !json.Value {
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

    fn handlePing(self: *Server, req: jsonrpc.Request) !void {
        try self.sendResult(req.id, types.EmptyResult{});
    }

    pub fn getMinLogLevel(self: *Server) types.LoggingLevel {
        return @enumFromInt(self.min_log_level.load(.monotonic));
    }

    pub fn setMinLogLevel(self: *Server, level: types.LoggingLevel) void {
        self.min_log_level.store(@intFromEnum(level), .monotonic);
    }

    fn handleLoggingSetLevel(self: *Server, req: jsonrpc.Request) !void {
        if (!self.options.enable_logging) {
            try self.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
            return;
        }

        const params = req.params orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };

        const obj = switch (params) {
            .object => |o| o,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "params must be an object"));
                return;
            },
        };

        const level_val = obj.get("level") orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing level"));
            return;
        };

        const level_str = switch (level_val) {
            .string => |s| s,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "params.level must be a string"));
                return;
            },
        };

        const level = std.meta.stringToEnum(types.LoggingLevel, level_str) orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown log level"));
            return;
        };

        self.setMinLogLevel(level);
        try self.sendResult(req.id, types.EmptyResult{});
    }

    pub fn sendResult(self: *Server, id: jsonrpc.RequestId, result: anytype) !void {
        const io = self.io orelse return error.IoNotSet;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        const writer = self.transport.getWriter(io);
        try envelope_codec.encodeResponseToWriter(writer, id, result);
        try writer.writeByte('\n');
        try writer.flush();
    }

    fn getCapabilities(self: *Server) types.ServerCapabilities {
        var caps = self.capabilities.advertise();
        if (std.mem.order(u8, self.negotiated_version, types.TASKS_MIN_PROTOCOL_VERSION) == .lt) {
            // Avoid advertising tasks to hosts validating older schemas.
            caps.tasks = null;
        }
        if (self.options.enable_logging) {
            caps.logging = .{};
        }
        return caps;
    }

    pub fn sendError(self: *Server, err: jsonrpc.Error) !void {
        const io = self.io orelse return error.IoNotSet;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        const writer = self.transport.getWriter(io);
        try envelope_codec.encodeErrorToWriter(writer, err.id, err.@"error");
        try writer.writeByte('\n');
        try writer.flush();
    }

    pub fn sendNotification(self: *Server, method: []const u8, params: anytype) !void {
        const io = self.io orelse return error.IoNotSet;
        self.io_mutex.lockUncancelable(io);
        defer self.io_mutex.unlock(io);
        const writer = self.transport.getWriter(io);
        try envelope_codec.encodeNotificationToWriter(writer, method, params);
        try writer.writeByte('\n');
        try writer.flush();
    }

    pub fn sendLogMessage(self: *Server, level: types.LoggingLevel, data: json.Value, logger: ?[]const u8) !void {
        if (!self.options.enable_logging) return;
        if (@intFromEnum(level) < self.min_log_level.load(.monotonic)) return;
        try self.sendNotification("notifications/message", types.LoggingMessageParams{
            .level = level,
            .logger = logger,
            .data = data,
        });
    }

    pub fn sendLogMessageRaw(self: *Server, level: types.LoggingLevel, data: json.Value, logger: ?[]const u8) !void {
        if (!self.options.enable_logging) return;
        try self.sendNotification("notifications/message", types.LoggingMessageParams{
            .level = level,
            .logger = logger,
            .data = data,
        });
    }

    pub fn sendToolListChanged(self: *Server) !void {
        try self.sendNotification("notifications/tools/list_changed", types.EmptyResult{});
    }

    pub fn sendResourceListChanged(self: *Server) !void {
        try self.sendNotification("notifications/resources/list_changed", types.EmptyResult{});
    }

    pub fn sendPromptListChanged(self: *Server) !void {
        try self.sendNotification("notifications/prompts/list_changed", types.EmptyResult{});
    }

    pub fn sendProgress(self: *Server, token: anytype, progress: f64, total: ?f64, message: ?[]const u8) !void {
        const progress_token: types.ProgressToken = switch (@TypeOf(token)) {
            types.ProgressToken => token,
            []const u8 => .{ .string = token },
            i64 => .{ .number = token },
            else => @compileError("Progress token must be string or i64"),
        };
        try self.sendNotification("notifications/progress", types.ProgressParams{
            .progressToken = progress_token,
            .progress = progress,
            .total = total,
            .message = message,
        });
    }

    fn freeImplementation(allocator: std.mem.Allocator, impl: types.Implementation) void {
        allocator.free(impl.name);
        allocator.free(impl.version);
        if (impl.title) |t| allocator.free(t);
        if (impl.description) |d| allocator.free(d);
    }
};

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

test "Server tool handler with user_data" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;
    server.capabilities.tasks.setIo(io);

    const Ctx = struct {
        prefix: []const u8,
        saw: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    const EmptyArgs = struct {};
    const EmptyArgsMapper = typed_codec.defaultMapper(EmptyArgs);
    var ctx = Ctx{ .prefix = "pfx:" };

    try server.capabilities.tools.addTyped(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = .{ .type = "object" },
    }, EmptyArgsMapper, struct {
        fn handler(user_data: ?*anyopaque, _: []const u8, _: ?EmptyArgs, _: ToolCallMeta, _: CancellationToken, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
            const c: *Ctx = @ptrCast(@alignCast(user_data.?));
            c.saw.store(true, .release);
            var result = types.OwnedCallToolResult.init(allocator);
            try result.addText(c.prefix);
            return result;
        }
    }.handler, &ctx);

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"task\":{}}}\n");

    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    var i: usize = 0;
    while (i < 200 and !ctx.saw.load(.acquire)) : (i += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(ctx.saw.load(.acquire));
}

test "Server tools/call runs synchronously when params.task is absent" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    var saw = std.atomic.Value(bool).init(false);
    const EmptyArgs = struct {};
    const EmptyArgsMapper = typed_codec.defaultMapper(EmptyArgs);

    try server.capabilities.tools.addTyped(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = .{ .type = "object" },
    }, EmptyArgsMapper, struct {
        fn handler(user_data: ?*anyopaque, _: []const u8, _: ?EmptyArgs, _: ToolCallMeta, _: CancellationToken, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(user_data.?));
            flag.store(true, .release);
            var result = types.OwnedCallToolResult.init(allocator);
            try result.addText("sync");
            return result;
        }
    }.handler, &saw);

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}\n");

    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    try std.testing.expect(saw.load(.acquire));
    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sync") != null);
}

test "Server tool handler receives tools/call _meta.progressToken" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;
    server.capabilities.tasks.setIo(io);

    var saw = std.atomic.Value(bool).init(false);
    const EmptyArgs = struct {};
    const EmptyArgsMapper = typed_codec.defaultMapper(EmptyArgs);

    try server.capabilities.tools.addTyped(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = .{ .type = "object" },
    }, EmptyArgsMapper, struct {
        fn handler(user_data: ?*anyopaque, _: []const u8, _: ?EmptyArgs, meta: ToolCallMeta, _: CancellationToken, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(user_data.?));
            var result = types.OwnedCallToolResult.init(allocator);
            if (meta.progressToken) |pt| switch (pt) {
                .string => |s| {
                    if (std.mem.eql(u8, s, "tok")) flag.store(true, .release);
                    try result.addText(s);
                },
                .number => |n| {
                    var buf: [32]u8 = undefined;
                    const txt = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "fmt-failed";
                    try result.addText(txt);
                },
            } else {
                try result.addText("no-token");
            }
            return result;
        }
    }.handler, &saw);

    try buffered.setInput(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"task\":{},\"_meta\":{\"progressToken\":\"tok\"}}}\n",
    );

    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    var i: usize = 0;
    while (i < 200 and !saw.load(.acquire)) : (i += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(saw.load(.acquire));
}

test "Server marks active request cancelled via notifications/cancelled" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    var active: Server.ActiveRequest = .{ .id = .{ .number = 1 } };
    cancellation_mod.registerActiveRequest(&server, io, &active);
    defer cancellation_mod.unregisterActiveRequest(&server, io, &active);

    const msg = try jsonrpc.Message.parse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}");
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

    try server.handleMessage(io, msg);

    try std.testing.expect(active.cancelled.load(.acquire));
}

test "Server on_notification hook fires" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    const Hook = struct {
        fn onNotification(user_data: ?*anyopaque, _: *Server, notif: jsonrpc.Notification) anyerror!void {
            const flag: *bool = @ptrCast(@alignCast(user_data.?));
            if (std.mem.eql(u8, notif.method, "notifications/roots/list_changed")) {
                flag.* = true;
            }
        }
    };

    var saw = false;
    var server = Server.init(
        std.testing.allocator,
        .{
            .name = "test-server",
            .version = "1.0.0",
            .user_data = &saw,
            .on_notification = Hook.onNotification,
        },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/roots/list_changed\"}\n");

    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    try std.testing.expect(saw);
}

test "Server init" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    _ = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    try std.testing.expectEqualStrings("test", server.options.name);
}

test "Server handle initialize" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"roots\":{\"listChanged\":true}},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n");

    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

    try server.handleMessage(io, msg);

    try std.testing.expect(server.client_capabilities != null);
    try std.testing.expect(server.client_capabilities.?.roots != null);
    try std.testing.expect(server.client_capabilities.?.roots.?.list_changed);

    const output = buffered.getOutput();
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test-server") != null);
}

test "Server roots/list sends request and parses response" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var duplex: transport_mod.DuplexTransport = undefined;
    duplex.init(std.testing.allocator);
    defer duplex.deinit(io);

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        duplex.endpointA().asTransport(),
    );
    defer server.deinit();
    server.io = io;

    const FakeClient = struct {
        fn run(ep: *transport_mod.DuplexTransport.Endpoint, io2: std.Io) !void {
            const msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

            const req = switch (msg) {
                .request => |r| r,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqualStrings("roots/list", req.method);
            const id_num = switch (req.id) {
                .number => |n| n,
                .string => return error.UnexpectedToken,
            };

            const response = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"roots\":[{{\"uri\":\"file:///repo\",\"name\":\"repo\"}},{{\"uri\":\"file:///tmp\"}}]}}}}",
                .{id_num},
            );
            defer std.testing.allocator.free(response);

            try ep.asTransport().write(io2, response);
            ep.asTransport().close(io2);
        }
    };

    var srv_future = try std.Io.concurrent(io, Server.run, .{ &server, io });
    var cli_future = try std.Io.concurrent(io, FakeClient.run, .{ duplex.endpointB(), io });

    var roots = try server.listRoots();
    defer roots.deinit();

    try cli_future.await(io);
    try srv_future.await(io);

    try std.testing.expectEqual(@as(usize, 2), roots.roots.items.len);
    try std.testing.expectEqualStrings("file:///repo", roots.roots.items[0].uri);
    try std.testing.expect(roots.roots.items[0].name != null);
    try std.testing.expectEqualStrings("repo", roots.roots.items[0].name.?);

    // Client observed request by responding; server parsed roots.
}

test "Server request timeout sends notifications/cancelled" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var duplex: transport_mod.DuplexTransport = undefined;
    duplex.init(std.testing.allocator);
    defer duplex.deinit(io);

    const timeout: Io.Clock.Duration = .{ .raw = Io.Duration.fromMilliseconds(10), .clock = .boot };

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0", .default_timeout = timeout },
        duplex.endpointA().asTransport(),
    );
    defer server.deinit();
    server.io = io;

    const FakeClient = struct {
        fn run(ep: *transport_mod.DuplexTransport.Endpoint, io2: std.Io) !void {
            const msg = (try ep.asTransport().read(io2, std.testing.allocator)) orelse return;
            defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

            const req = switch (msg) {
                .request => |r| r,
                else => return error.UnexpectedToken,
            };
            try std.testing.expectEqualStrings("roots/list", req.method);
            const rid = req.id;

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
            const got: jsonrpc.RequestId = switch (rid_val) {
                .string => |s| .{ .string = s },
                .integer => |n| .{ .number = n },
                .number_string => |s| .{ .number = try std.fmt.parseInt(i64, s, 10) },
                else => return error.UnexpectedToken,
            };
            try std.testing.expect(rid.eql(got));
            ep.asTransport().close(io2);
        }
    };

    // Use native thread for FakeClient to avoid Io.concurrent issues
    const ClientThread = struct {
        ep: *transport_mod.DuplexTransport.Endpoint,
        io: std.Io,
        fn run(self: @This()) void {
            FakeClient.run(self.ep, self.io) catch {};
        }
    };

    const client_ctx = ClientThread{
        .ep = duplex.endpointB(),
        .io = io,
    };
    const client_thread = try std.Thread.spawn(.{}, ClientThread.run, .{client_ctx});

    try std.testing.expectError(error.RequestTimeout, server.listRoots());

    client_thread.join();
}

test "Server tasks/get returns task fields directly" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;
    server.capabilities.tasks.setIo(io);

    _ = try server.capabilities.tasks.createTask(.{ .ttl = 60000, .pollInterval = null });

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"task-1\"}}\n");
    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    const out = buffered.getOutput();
    const nl = std.mem.indexOfScalar(u8, out, '\n') orelse return error.TestUnexpectedResult;
    const out_msg = try jsonrpc.Message.parse(std.testing.allocator, out[0..nl]);
    defer jsonrpc.Message.freeMessage(std.testing.allocator, out_msg);
    try std.testing.expect(out_msg == .response);
    const result_obj = switch (out_msg.response.result) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(result_obj.get("taskId") != null);
    try std.testing.expect(result_obj.get("task") == null);
}

test "Server initialize advertises logging capability when enabled" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0", .enable_logging = true },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n");
    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"logging\":{}") != null);
}

test "Server initialize omits logging capability when disabled" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0", .enable_logging = false },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n");
    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"logging\"") == null);
}

test "Server initialize omits tasks capability for protocol versions before 2025-11-25" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0", .enable_tasks = true },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n");
    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"tasks\"") == null);
}

test "Server initialize advertises tasks capability for protocol version 2025-11-25" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0", .enable_tasks = true },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n");
    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"tasks\"") != null);
}

test "Server logging/setLevel updates min log level" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0", .enable_logging = true, .default_log_level = .info },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"warning\"}}\n");
    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(io, msg);

    try std.testing.expectEqual(types.LoggingLevel.warning, server.getMinLogLevel());
    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"result\":{}") != null);
}

test "Server sendLogMessage filters below min level" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0", .enable_logging = true, .default_log_level = .warning },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    buffered.clearOutput();
    try server.sendLogMessage(.info, .{ .string = "low" }, "test");
    try std.testing.expectEqual(@as(usize, 0), buffered.getOutput().len);

    try server.sendLogMessage(.@"error", .{ .string = "high" }, "test");
    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"method\":\"notifications/message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"error\"") != null);
}

test "Server notifications/tasks/status params are task fields directly" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    const task = types.Task{
        .id = "task-1",
        .status = .running,
        .createdAt = "2026-02-05T00:00:00Z",
        .updatedAt = "2026-02-05T00:00:01Z",
        .ttl = 60000,
        .pollInterval = null,
    };

    try server.sendNotification("notifications/tasks/status", task);
    const out = buffered.getOutput();
    const nl = std.mem.indexOfScalar(u8, out, '\n') orelse return error.TestUnexpectedResult;
    const out_msg = try jsonrpc.Message.parse(std.testing.allocator, out[0..nl]);
    defer jsonrpc.Message.freeMessage(std.testing.allocator, out_msg);
    try std.testing.expect(out_msg == .notification);
    const params_obj = switch (out_msg.notification.params orelse return error.TestUnexpectedResult) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(params_obj.get("taskId") != null);
    try std.testing.expect(params_obj.get("task") == null);
}

test "Server tools/list includes inputSchema" {
    var tio: TestIo = undefined;
    tio.init(std.testing.allocator);
    defer tio.deinit();
    const io = tio.io;

    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();
    server.io = io;

    // addTyped auto-generates schema from EchoArgs
    const EchoArgs = struct {
        message: []const u8,
    };
    const EchoArgsMapper = typed_codec.defaultMapper(EchoArgs);

    try server.capabilities.tools.addTyped(.{
        .name = "echo",
        .description = "Echo",
    }, EchoArgsMapper, struct {
        fn handler(_: ?*anyopaque, _: []const u8, _: ?EchoArgs, _: ToolCallMeta, _: CancellationToken, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
            var result = types.OwnedCallToolResult.init(allocator);
            try result.addText("ok");
            return result;
        }
    }.handler, null);

    buffered.clearOutput();
    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n");

    const msg = try buffered.asTransport().read(io, std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

    try server.handleMessage(io, msg);

    const output = buffered.getOutput();
    const nl = std.mem.indexOfScalar(u8, output, '\n') orelse output.len;
    const line = output[0..nl];

    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };
    const result_val = root_obj.get("result") orelse return error.UnexpectedToken;
    const result_obj = switch (result_val) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };
    const tools_val = result_obj.get("tools") orelse return error.UnexpectedToken;
    const tools_arr = switch (tools_val) {
        .array => |a| a,
        else => return error.UnexpectedToken,
    };
    try std.testing.expectEqual(@as(usize, 1), tools_arr.items.len);

    const tool0_obj = switch (tools_arr.items[0]) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };
    const schema_val = tool0_obj.get("inputSchema") orelse return error.UnexpectedToken;
    const schema_obj = switch (schema_val) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };

    const type_val = schema_obj.get("type") orelse return error.UnexpectedToken;
    try std.testing.expectEqualStrings("object", switch (type_val) {
        .string => |s| s,
        else => return error.UnexpectedToken,
    });

    const props_val = schema_obj.get("properties") orelse return error.UnexpectedToken;
    const props_obj = switch (props_val) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };
    const msg_val = props_obj.get("message") orelse return error.UnexpectedToken;
    const msg_obj = switch (msg_val) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };
    const msg_type_val = msg_obj.get("type") orelse return error.UnexpectedToken;
    try std.testing.expectEqualStrings("string", switch (msg_type_val) {
        .string => |s| s,
        else => return error.UnexpectedToken,
    });

    const required_val = schema_obj.get("required") orelse return error.UnexpectedToken;
    const required_arr = switch (required_val) {
        .array => |a| a,
        else => return error.UnexpectedToken,
    };
    try std.testing.expect(required_arr.items.len >= 1);
    try std.testing.expectEqualStrings("message", switch (required_arr.items[0]) {
        .string => |s| s,
        else => return error.UnexpectedToken,
    });
}
