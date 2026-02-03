const std = @import("std");
const json = std.json;
const jsonrpc = @import("jsonrpc.zig");
const types = @import("types.zig");
const transport_mod = @import("transport.zig");
const Io = std.Io;

pub const Transport = transport_mod.Transport;

pub const ClientOptions = struct {
    name: []const u8,
    version: []const u8,
    capabilities: types.ClientCapabilities = .{},
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    options: ClientOptions,
    transport: *Transport,
    next_request_id: i64 = 1,
    server_capabilities: ?types.ServerCapabilities = null,
    server_info: ?types.Implementation = null,
    negotiated_version: ?[]const u8 = null,
    server_instructions: ?[]const u8 = null,
    server_info_owned: bool = false,
    negotiated_version_owned: bool = false,
    server_instructions_owned: bool = false,
    roots: std.ArrayList(types.Root) = .empty,

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

        const result_value = try self.sendRequest("initialize", params);
        defer jsonrpc.Message.freeValue(self.allocator, result_value);

        const result = try parseInitializeResult(self.allocator, result_value);
        self.setServerStateFromInitializeResult(result);

        try self.sendInitializedNotification();

        return result;
    }

    fn sendInitializedNotification(self: *Client) !void {
        try self.sendNotificationRaw("notifications/initialized", null);
    }

    pub fn ping(self: *Client) !void {
        _ = try self.sendRequest("ping", null);
    }

    pub fn listTools(self: *Client) !json.Value {
        return try self.sendRequest("tools/list", null);
    }

    pub fn callTool(self: *Client, name: []const u8, arguments: ?json.Value) !json.Value {
        var params_obj = json.ObjectMap.init(self.allocator);
        defer params_obj.deinit();
        try params_obj.put("name", .{ .string = name });
        if (arguments) |args| {
            try params_obj.put("arguments", args);
        }
        return try self.sendRequest("tools/call", .{ .object = params_obj });
    }

    pub fn listResources(self: *Client) !json.Value {
        return try self.sendRequest("resources/list", null);
    }

    pub fn readResource(self: *Client, uri: []const u8) !json.Value {
        var params_obj = json.ObjectMap.init(self.allocator);
        defer params_obj.deinit();
        try params_obj.put("uri", .{ .string = uri });
        return try self.sendRequest("resources/read", .{ .object = params_obj });
    }

    pub fn listPrompts(self: *Client) !json.Value {
        return try self.sendRequest("prompts/list", null);
    }

    pub fn getPrompt(self: *Client, name: []const u8, arguments: ?json.ObjectMap) !json.Value {
        var params_obj = json.ObjectMap.init(self.allocator);
        defer params_obj.deinit();
        try params_obj.put("name", .{ .string = name });
        if (arguments) |args| {
            try params_obj.put("arguments", .{ .object = args });
        }
        return try self.sendRequest("prompts/get", .{ .object = params_obj });
    }

    fn sendRequest(self: *Client, method: []const u8, params: anytype) !json.Value {
        const id = self.next_request_id;
        self.next_request_id += 1;

        var aw: Io.Writer.Allocating = .init(self.allocator);
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
        try self.transport.write(aw.written());

        return try self.waitForResponse(id);
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

    fn waitForResponse(self: *Client, expected_id: i64) !json.Value {
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
                .notification => {},
                .request => |req| try self.handleIncomingRequest(req),
            }
        }
    }

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
        var aw: Io.Writer.Allocating = .init(self.allocator);
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
        try self.transport.write(aw.written());
    }

    pub fn sendRootsListChanged(self: *Client) !void {
        const roots_cap = self.options.capabilities.roots orelse return;
        if (!roots_cap.list_changed) return;
        try self.sendNotificationRaw("notifications/roots/list_changed", null);
    }

    fn sendResult(self: *Client, id: jsonrpc.RequestId, result: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.allocator);
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
        try self.transport.write(aw.written());
    }

    fn sendError(self: *Client, err: jsonrpc.Error) !void {
        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try err.jsonStringify(&jws);

        try aw.writer.flush();
        try self.transport.write(aw.written());
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

fn parseInitializeResult(allocator: std.mem.Allocator, value: json.Value) !types.InitializeResult {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidInitializeResult,
    };

    const protocol_val = obj.get("protocolVersion") orelse return error.InvalidInitializeResult;
    const protocol_version = switch (protocol_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidInitializeResult,
    };
    errdefer allocator.free(protocol_version);

    const server_info_val = obj.get("serverInfo") orelse return error.InvalidInitializeResult;
    const server_info = try parseImplementationFromValue(allocator, server_info_val);
    errdefer freeImplementation(allocator, server_info);

    const instructions_val = obj.get("instructions");
    const instructions: ?[]const u8 = if (instructions_val) |iv| switch (iv) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    errdefer if (instructions) |i| allocator.free(@constCast(i));

    const caps_val = obj.get("capabilities");
    const caps: types.ServerCapabilities = if (caps_val) |cv| parseServerCapabilities(cv) else .{};

    return .{
        .protocolVersion = protocol_version,
        .capabilities = caps,
        .serverInfo = server_info,
        .instructions = instructions,
    };
}

fn parseImplementationFromValue(allocator: std.mem.Allocator, value: json.Value) !types.Implementation {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidInitializeResult,
    };

    const name_val = obj.get("name") orelse return error.InvalidInitializeResult;
    const version_val = obj.get("version") orelse return error.InvalidInitializeResult;

    const name = switch (name_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidInitializeResult,
    };
    errdefer allocator.free(name);

    const version = switch (version_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidInitializeResult,
    };
    errdefer allocator.free(version);

    const title = if (obj.get("title")) |t| switch (t) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    errdefer if (title) |t| allocator.free(@constCast(t));

    const description = if (obj.get("description")) |d| switch (d) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    errdefer if (description) |d| allocator.free(@constCast(d));

    return .{
        .name = name,
        .version = version,
        .title = title,
        .description = description,
    };
}

fn parseServerCapabilities(value: json.Value) types.ServerCapabilities {
    const obj = switch (value) {
        .object => |o| o,
        else => return .{},
    };

    var caps: types.ServerCapabilities = .{};

    if (obj.get("prompts")) |p| {
        if (p == .object) {
            const list_changed = getBool(p.object, "listChanged");
            caps.prompts = .{ .list_changed = list_changed };
        } else {
            caps.prompts = .{};
        }
    }

    if (obj.get("resources")) |r| {
        if (r == .object) {
            const subscribe = getBool(r.object, "subscribe");
            const list_changed = getBool(r.object, "listChanged");
            caps.resources = .{ .subscribe = subscribe, .list_changed = list_changed };
        } else {
            caps.resources = .{};
        }
    }

    if (obj.get("tools")) |t| {
        if (t == .object) {
            const list_changed = getBool(t.object, "listChanged");
            caps.tools = .{ .list_changed = list_changed };
        } else {
            caps.tools = .{};
        }
    }

    if (obj.get("logging") != null) caps.logging = .{};
    if (obj.get("completions") != null) caps.completions = .{};

    return caps;
}

fn getBool(obj: json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn freeImplementation(allocator: std.mem.Allocator, impl: types.Implementation) void {
    allocator.free(@constCast(impl.name));
    allocator.free(@constCast(impl.version));
    if (impl.title) |t| allocator.free(@constCast(t));
    if (impl.description) |d| allocator.free(@constCast(d));
}

test "Client init" {
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
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    try buffered.setInput(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{},\"resources\":{\"subscribe\":true}},\"serverInfo\":{\"name\":\"srv\",\"version\":\"1.2.3\",\"title\":\"T\"},\"instructions\":\"hi\"}}\n",
    );

    var client = Client.init(
        std.testing.allocator,
        .{ .name = "test-client", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer client.deinit();

    const result = try client.initialize();

    try std.testing.expectEqualStrings("2025-03-26", result.protocolVersion);
    try std.testing.expectEqualStrings("srv", result.serverInfo.name);
    try std.testing.expectEqualStrings("1.2.3", result.serverInfo.version);
    try std.testing.expect(result.serverInfo.title != null);
    try std.testing.expectEqualStrings("T", result.serverInfo.title.?);
    try std.testing.expect(result.instructions != null);
    try std.testing.expectEqualStrings("hi", result.instructions.?);
    try std.testing.expect(result.capabilities.tools != null);
    try std.testing.expect(result.capabilities.resources != null);

    const out = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"method\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "notifications/initialized") != null);
}

test "Client initialize sends roots capability with listChanged" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    try buffered.setInput(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"serverInfo\":{\"name\":\"srv\",\"version\":\"1.2.3\"}}}\n",
    );

    var client = Client.init(
        std.testing.allocator,
        .{
            .name = "test-client",
            .version = "1.0.0",
            .capabilities = .{ .roots = .{ .list_changed = true } },
        },
        buffered.asTransport(),
    );
    defer client.deinit();

    _ = try client.initialize();

    const out = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"roots\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"listChanged\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "list_changed") == null);
}

test "Client responds to roots/list while waiting for response" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    try buffered.setInput(
        "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"roots/list\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n",
    );

    var client = Client.init(
        std.testing.allocator,
        .{
            .name = "test-client",
            .version = "1.0.0",
            .capabilities = .{ .roots = .{} },
        },
        buffered.asTransport(),
    );
    defer client.deinit();

    try client.setRoots(&[_]types.Root{
        .{ .uri = "file:///repo", .name = "repo" },
        .{ .uri = "file:///tmp" },
    });

    try client.ping();

    const out = buffered.getOutput();
    var it = std.mem.splitScalar(u8, out, '\n');
    var saw_roots_result = false;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const id_val = root_obj.get("id") orelse continue;
        if (id_val != .integer or id_val.integer != 99) continue;

        const result_val = root_obj.get("result") orelse return error.UnexpectedToken;
        const result_obj = switch (result_val) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        const roots_val = result_obj.get("roots") orelse return error.UnexpectedToken;
        const roots_arr = switch (roots_val) {
            .array => |a| a,
            else => return error.UnexpectedToken,
        };
        try std.testing.expectEqual(@as(usize, 2), roots_arr.items.len);
        saw_roots_result = true;
    }
    try std.testing.expect(saw_roots_result);
}
