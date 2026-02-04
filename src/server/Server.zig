const std = @import("std");
const json = std.json;
const jsonrpc = @import("../jsonrpc.zig");
const types = @import("../types.zig");
const transport_mod = @import("../transport.zig");
const common = @import("common.zig");
const cancellation_mod = @import("cancellation.zig");
const cascade_mod = @import("capabilities/Cascade.zig");
const Io = std.Io;

pub const Transport = transport_mod.Transport;

pub const ToolHandler = common.ToolHandler;
pub const ToolCallMeta = common.ToolCallMeta;
pub const CancellationToken = common.CancellationToken;

pub const ResourceHandler = *const fn (
    uri: []const u8,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedReadResourceResult;

pub const ResourceHandlerWithUserData = *const fn (
    user_data: ?*anyopaque,
    uri: []const u8,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedReadResourceResult;

pub const PromptHandler = *const fn (
    name: []const u8,
    arguments: ?json.ObjectMap,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedGetPromptResult;

pub const PromptHandlerWithUserData = *const fn (
    user_data: ?*anyopaque,
    name: []const u8,
    arguments: ?json.ObjectMap,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedGetPromptResult;

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

    allocator: std.mem.Allocator,
    options: ServerOptions,
    transport: *Transport,
    initialization_state: InitializationState = .not_initialized,
    client_capabilities: ?types.ClientCapabilities = null,
    client_info: ?types.Implementation = null,
    negotiated_version: []const u8 = types.DEFAULT_NEGOTIATED_VERSION,
    negotiated_version_owned: ?[]u8 = null,
    client_info_owned: bool = false,
    next_request_id: i64 = 1,
    user_data: ?*anyopaque = null,
    on_notification: ?NotificationHandler = null,

    ts_allocator: std.heap.ThreadSafeAllocator,
    io_mutex: std.Thread.Mutex = .{},

    active_requests_mutex: std.Thread.Mutex = .{},
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
            .ts_allocator = .{ .child_allocator = allocator },
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
    }

    pub fn getAllocator(self: *Server) std.mem.Allocator {
        // Even if we're not running workers, using the wrapped allocator is cheap and ensures that
        // frees from other threads (e.g. worker-owned messages) are serialized.
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
        self.sendNotification("notifications/tasks/status", types.TaskStatusNotificationParams{ .task = task }) catch {};
    }

    pub fn run(self: *Server) !void {
        self.attachCapabilities();

        while (true) {
            const msg = try self.transport.read(self.getAllocator()) orelse break;

            defer jsonrpc.Message.freeMessage(self.getAllocator(), msg);
            try self.handleMessage(msg);
        }
    }

    /// Sends `roots/list` to the connected client and returns the client's current roots.
    /// Caller owns the returned value and must call `deinit()`.
    pub fn listRoots(self: *Server) !types.OwnedListRootsResult {
        const result_value = try self.sendRequest("roots/list", null);
        defer jsonrpc.Message.freeValue(self.allocator, result_value);
        return try self.parseListRootsResult(result_value);
    }

    pub fn handleMessage(self: *Server, msg: jsonrpc.Message) !void {
        self.attachCapabilities();
        switch (msg) {
            .request => |req| try self.handleRequest(req),
            .notification => |notif| try self.handleNotification(notif),
            .response => {},
            .@"error" => {},
        }
    }

    fn handleRequest(self: *Server, req: jsonrpc.Request) !void {
        if (std.mem.eql(u8, req.method, "initialize")) {
            try self.handleInitialize(req);
        } else if (std.mem.eql(u8, req.method, "ping")) {
            try self.handlePing(req);
        } else if (try self.capabilities.handleRequest(self, req)) {
            // handled by a capability
        } else {
            try self.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
        }
    }

    fn handleNotification(self: *Server, notif: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notif.method, "notifications/initialized")) {
            self.initialization_state = .initialized;
        } else if (std.mem.eql(u8, notif.method, "notifications/cancelled")) {
            cancellation_mod.handleCancelledNotification(self, notif);
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
                if (obj.get("protocolVersion")) |pv| {
                    if (pv == .string) {
                        const duped = try self.allocator.dupe(u8, pv.string);
                        if (self.negotiated_version_owned) |v| self.allocator.free(v);
                        self.negotiated_version_owned = duped;
                        self.negotiated_version = duped;
                    }
                }
                if (obj.get("clientInfo")) |ci| {
                    if (ci == .object) {
                        const parsed: ?types.Implementation = parseImplementation(self.allocator, ci.object) catch null;
                        if (parsed) |info| {
                            if (self.client_info_owned) {
                                if (self.client_info) |old| freeImplementation(self.allocator, old);
                            }
                            self.client_info_owned = true;
                            self.client_info = info;
                        }
                    }
                }
                if (obj.get("capabilities")) |caps_val| {
                    if (caps_val == .object) {
                        self.client_capabilities = self.parseClientCapabilities(caps_val.object);
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

    fn parseClientCapabilities(_: *Server, obj: json.ObjectMap) types.ClientCapabilities {
        var caps: types.ClientCapabilities = .{};

        if (obj.get("roots")) |r| {
            if (r == .object) {
                const list_changed = getBool(r.object, "listChanged");
                caps.roots = .{ .list_changed = list_changed };
            } else {
                caps.roots = .{};
            }
        }

        if (obj.get("sampling") != null) caps.sampling = .{};
        if (obj.get("elicitation") != null) caps.elicitation = .{};

        return caps;
    }

    fn parseListRootsResult(self: *Server, value: json.Value) !types.OwnedListRootsResult {
        const obj = switch (value) {
            .object => |o| o,
            else => return error.InvalidRootsListResult,
        };

        const roots_val = obj.get("roots") orelse return error.InvalidRootsListResult;
        const roots_arr = switch (roots_val) {
            .array => |a| a,
            else => return error.InvalidRootsListResult,
        };

        var result = types.OwnedListRootsResult.init(self.allocator);
        errdefer result.deinit();

        for (roots_arr.items) |item| {
            const root_obj = switch (item) {
                .object => |o| o,
                else => return error.InvalidRootsListResult,
            };

            const uri_val = root_obj.get("uri") orelse return error.InvalidRootsListResult;
            const uri = switch (uri_val) {
                .string => |s| s,
                else => return error.InvalidRootsListResult,
            };

            const name_val = root_obj.get("name");
            const name: ?[]const u8 = if (name_val) |nv| switch (nv) {
                .string => |s| s,
                else => return error.InvalidRootsListResult,
            } else null;

            try result.addRoot(uri, name);
        }

        return result;
    }

    fn sendRequest(self: *Server, method: []const u8, params: anytype) !json.Value {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var aw: Io.Writer.Allocating = .init(self.getAllocator());
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write("2.0");
        try jws.objectField("id");
        try jws.write(id);
        try jws.objectField("method");
        try jws.write(method);
        if (@TypeOf(params) != @TypeOf(null)) {
            try jws.objectField("params");
            try serializeParams(&jws, params);
        }
        try jws.endObject();

        try aw.writer.flush();
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        try self.transport.write(aw.written());

        return try self.waitForResponse(id);
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

    fn waitForResponse(self: *Server, expected_id: i64) !json.Value {
        while (true) {
            var msg = try self.transport.read(self.allocator) orelse return error.ConnectionClosed;
            defer jsonrpc.Message.freeMessage(self.allocator, msg);

            switch (msg) {
                .response => |*resp| {
                    const matches = switch (resp.id) {
                        .number => |n| n == expected_id,
                        .string => false,
                    };
                    if (matches) {
                        const result = resp.result;
                        resp.result = .null; // transfer ownership to caller
                        return result;
                    }
                },
                .@"error" => |err| {
                    if (err.id) |resp_id| {
                        const matches = switch (resp_id) {
                            .number => |n| n == expected_id,
                            .string => false,
                        };
                        if (matches) return error.RequestFailed;
                    }
                },
                .notification => |notif| try self.handleNotification(notif),
                .request => |req| try self.handleRequest(req),
            }
        }
    }

    fn handlePing(self: *Server, req: jsonrpc.Request) !void {
        try self.sendResult(req.id, types.EmptyResult{});
    }

    pub fn sendResult(self: *Server, id: jsonrpc.RequestId, result: anytype) !void {
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
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        try self.transport.write(aw.written());
    }

    fn getCapabilities(self: *Server) types.ServerCapabilities {
        return self.capabilities.advertise();
    }

    pub fn sendError(self: *Server, err: jsonrpc.Error) !void {
        var aw: Io.Writer.Allocating = .init(self.getAllocator());
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try err.jsonStringify(&jws);

        try aw.writer.flush();
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        try self.transport.write(aw.written());
    }

    fn getBool(obj: json.ObjectMap, key: []const u8) bool {
        const v = obj.get(key) orelse return false;
        return switch (v) {
            .bool => |b| b,
            else => false,
        };
    }

    pub fn sendNotification(self: *Server, method: []const u8, params: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.getAllocator());
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write("2.0");
        try jws.objectField("method");
        try jws.write(method);
        try jws.objectField("params");
        try params.jsonStringify(&jws);
        try jws.endObject();

        try aw.writer.flush();
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        try self.transport.write(aw.written());
    }

    pub fn sendLogMessage(self: *Server, level: types.LoggingLevel, data: json.Value, logger: ?[]const u8) !void {
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

    fn parseImplementation(allocator: std.mem.Allocator, obj: json.ObjectMap) !types.Implementation {
        const name_val = obj.get("name") orelse return error.InvalidRequest;
        const version_val = obj.get("version") orelse return error.InvalidRequest;

        const name = switch (name_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidRequest,
        };
        errdefer allocator.free(name);

        const version = switch (version_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidRequest,
        };
        errdefer allocator.free(version);

        const title = if (obj.get("title")) |t| switch (t) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        } else null;
        errdefer if (title) |t| allocator.free(t);

        const description = if (obj.get("description")) |d| switch (d) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        } else null;

        return .{
            .name = name,
            .version = version,
            .title = title,
            .description = description,
        };
    }

    fn freeImplementation(allocator: std.mem.Allocator, impl: types.Implementation) void {
        allocator.free(impl.name);
        allocator.free(impl.version);
        if (impl.title) |t| allocator.free(t);
        if (impl.description) |d| allocator.free(d);
    }
};

test "Server tool handler with user_data" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    const Ctx = struct {
        prefix: []const u8,
        saw: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var ctx = Ctx{ .prefix = "pfx:" };

    try server.capabilities.tools.addWithUserData(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = .{ .type = "object" },
    }, struct {
        fn handler(user_data: ?*anyopaque, _: []const u8, _: ?json.Value, _: ToolCallMeta, _: CancellationToken, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
            const c: *Ctx = @ptrCast(@alignCast(user_data.?));
            c.saw.store(true, .release);
            var result = types.OwnedCallToolResult.init(allocator);
            try result.addText(c.prefix);
            return result;
        }
    }.handler, &ctx);

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"task\":{}}}\n");

    const msg = try buffered.asTransport().read(std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(msg);

    var i: usize = 0;
    while (i < 200 and !ctx.saw.load(.acquire)) : (i += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(ctx.saw.load(.acquire));
}

test "Server tool handler receives tools/call _meta.progressToken" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    var saw = std.atomic.Value(bool).init(false);

    try server.capabilities.tools.addWithUserData(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = .{ .type = "object" },
    }, struct {
        fn handler(user_data: ?*anyopaque, _: []const u8, _: ?json.Value, meta: ToolCallMeta, _: CancellationToken, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
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

    const msg = try buffered.asTransport().read(std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(msg);

    var i: usize = 0;
    while (i < 200 and !saw.load(.acquire)) : (i += 1) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(saw.load(.acquire));
}

test "Server marks active request cancelled via notifications/cancelled" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    var active: Server.ActiveRequest = .{ .id = .{ .number = 1 } };
    cancellation_mod.registerActiveRequest(&server, &active);
    defer cancellation_mod.unregisterActiveRequest(&server, &active);

    const msg = try jsonrpc.Message.parse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}");
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

    try server.handleMessage(msg);

    try std.testing.expect(active.cancelled.load(.acquire));
}

test "Server on_notification hook fires" {
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

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/roots/list_changed\"}\n");

    const msg = try buffered.asTransport().read(std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(msg);

    try std.testing.expect(saw);
}

test "Server init" {
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
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"roots\":{\"listChanged\":true}},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n");

    const msg = try buffered.asTransport().read(std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

    try server.handleMessage(msg);

    try std.testing.expect(server.client_capabilities != null);
    try std.testing.expect(server.client_capabilities.?.roots != null);
    try std.testing.expect(server.client_capabilities.?.roots.?.list_changed);

    const output = buffered.getOutput();
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test-server") != null);
}

test "Server roots/list sends request and parses response" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    try buffered.setInput(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"roots\":[{\"uri\":\"file:///repo\",\"name\":\"repo\"},{\"uri\":\"file:///tmp\"}]}}\n",
    );

    var roots = try server.listRoots();
    defer roots.deinit();

    try std.testing.expectEqual(@as(usize, 2), roots.roots.items.len);
    try std.testing.expectEqualStrings("file:///repo", roots.roots.items[0].uri);
    try std.testing.expect(roots.roots.items[0].name != null);
    try std.testing.expectEqualStrings("repo", roots.roots.items[0].name.?);

    const out = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"method\":\"roots/list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"params\"") == null);
}

test "Server tools/list includes inputSchema" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    const schema = .{
        .type = "object",
        .properties = .{
            .message = .{ .type = "string" },
        },
        .required = &[_][]const u8{ "message" },
    };

    try server.capabilities.tools.add(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = schema,
    }, struct {
        fn handler(_: ?*anyopaque, _: []const u8, _: ?json.Value, _: ToolCallMeta, _: CancellationToken, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
            var result = types.OwnedCallToolResult.init(allocator);
            try result.addText("ok");
            return result;
        }
    }.handler);

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n");

    const msg = try buffered.asTransport().read(std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

    try server.handleMessage(msg);

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
