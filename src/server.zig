const std = @import("std");
const json = std.json;
const jsonrpc = @import("jsonrpc.zig");
const types = @import("types.zig");
const transport_mod = @import("transport.zig");
const Io = std.Io;

pub const Transport = transport_mod.Transport;

pub const ToolHandler = *const fn (
    name: []const u8,
    arguments: ?json.Value,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedCallToolResult;

pub const ResourceHandler = *const fn (
    uri: []const u8,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedReadResourceResult;

pub const PromptHandler = *const fn (
    name: []const u8,
    arguments: ?json.ObjectMap,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedGetPromptResult;

pub const ServerOptions = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
};

pub const InitializationState = enum {
    not_initialized,
    initializing,
    initialized,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    transport: *Transport,
    initialization_state: InitializationState = .not_initialized,
    client_capabilities: ?types.ClientCapabilities = null,
    client_info: ?types.Implementation = null,
    negotiated_version: []const u8 = types.DEFAULT_NEGOTIATED_VERSION,
    negotiated_version_owned: ?[]u8 = null,
    client_info_owned: bool = false,

    tools: std.StringHashMap(ToolInfo),
    resources: std.StringHashMap(ResourceInfo),
    prompts: std.StringHashMap(PromptInfo),

    pub const ToolInfo = struct {
        tool: types.Tool,
        handler: ToolHandler,
    };

    pub const ResourceInfo = struct {
        resource: types.Resource,
        handler: ResourceHandler,
    };

    pub const PromptInfo = struct {
        prompt: types.Prompt,
        handler: PromptHandler,
    };

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions, transport: *Transport) Server {
        return .{
            .allocator = allocator,
            .options = options,
            .transport = transport,
            .tools = std.StringHashMap(ToolInfo).init(allocator),
            .resources = std.StringHashMap(ResourceInfo).init(allocator),
            .prompts = std.StringHashMap(PromptInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.negotiated_version_owned) |v| self.allocator.free(v);
        if (self.client_info_owned) {
            if (self.client_info) |info| freeImplementation(self.allocator, info);
        }

        {
            var it = self.tools.valueIterator();
            while (it.next()) |info| {
                info.tool.deinit(self.allocator);
            }
        }
        self.tools.deinit();
        self.resources.deinit();
        self.prompts.deinit();
    }

    pub fn addTool(
        self: *Server,
        tool: anytype,
        handler: ToolHandler,
    ) !void {
        const T = @TypeOf(tool);

        if (!@hasField(T, "name")) @compileError("addTool: tool must have a `name` field");
        const name: []const u8 = tool.name;

        const description: ?[]const u8 = if (@hasField(T, "description")) tool.description else null;

        const schema_json: []u8 = if (@hasField(T, "inputSchemaJson")) blk: {
            const s: []const u8 = tool.inputSchemaJson;
            break :blk try self.allocator.dupe(u8, s);
        } else if (@hasField(T, "inputSchema")) blk: {
            const S = @TypeOf(tool.inputSchema);
            if (S == []const u8 or S == []u8) {
                break :blk try self.allocator.dupe(u8, tool.inputSchema);
            }
            break :blk try types.stringifyJsonAlloc(self.allocator, tool.inputSchema);
        } else {
            @compileError("addTool: tool must have `inputSchema` (any JSON-serializable value) or `inputSchemaJson` ([]const u8) field");
        };

        try self.tools.put(name, .{
            .tool = .{
                .name = name,
                .description = description,
                .inputSchemaJson = schema_json,
                .inputSchemaJsonOwned = true,
            },
            .handler = handler,
        });
    }

    pub fn addResource(
        self: *Server,
        resource: types.Resource,
        handler: ResourceHandler,
    ) !void {
        try self.resources.put(resource.uri, .{ .resource = resource, .handler = handler });
    }

    pub fn addPrompt(
        self: *Server,
        prompt: types.Prompt,
        handler: PromptHandler,
    ) !void {
        try self.prompts.put(prompt.name, .{ .prompt = prompt, .handler = handler });
    }

    pub fn run(self: *Server) !void {
        while (true) {
            const msg = try self.transport.read(self.allocator) orelse break;
            defer jsonrpc.Message.freeMessage(self.allocator, msg);
            try self.handleMessage(msg);
        }
    }

    pub fn handleMessage(self: *Server, msg: jsonrpc.Message) !void {
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
        } else if (std.mem.eql(u8, req.method, "tools/list")) {
            try self.handleListTools(req);
        } else if (std.mem.eql(u8, req.method, "tools/call")) {
            try self.handleCallTool(req);
        } else if (std.mem.eql(u8, req.method, "resources/list")) {
            try self.handleListResources(req);
        } else if (std.mem.eql(u8, req.method, "resources/read")) {
            try self.handleReadResource(req);
        } else if (std.mem.eql(u8, req.method, "prompts/list")) {
            try self.handleListPrompts(req);
        } else if (std.mem.eql(u8, req.method, "prompts/get")) {
            try self.handleGetPrompt(req);
        } else {
            try self.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
        }
    }

    fn handleNotification(self: *Server, notif: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notif.method, "notifications/initialized")) {
            self.initialization_state = .initialized;
        } else if (std.mem.eql(u8, notif.method, "notifications/cancelled")) {
            // Handle cancellation - TODO: implement request cancellation
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

    fn handlePing(self: *Server, req: jsonrpc.Request) !void {
        try self.sendResult(req.id, types.EmptyResult{});
    }

    fn handleListTools(self: *Server, req: jsonrpc.Request) !void {
        var tool_list: std.ArrayList(types.Tool) = .empty;
        defer tool_list.deinit(self.allocator);

        var it = self.tools.valueIterator();
        while (it.next()) |info| {
            try tool_list.append(self.allocator, info.tool);
        }

        const result = types.ListToolsResult{
            .tools = tool_list.items,
        };

        try self.sendResult(req.id, result);
    }

    fn handleCallTool(self: *Server, req: jsonrpc.Request) !void {
        const params = req.params orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };

        const params_obj = switch (params) {
            .object => |o| o,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "Params must be object"));
                return;
            },
        };

        const name_val = params_obj.get("name") orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing name"));
            return;
        };

        const name = switch (name_val) {
            .string => |s| s,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "Name must be string"));
                return;
            },
        };

        const tool_info = self.tools.get(name) orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown tool"));
            return;
        };

        const arguments = params_obj.get("arguments");

        var result = tool_info.handler(name, arguments, self.allocator) catch |err| {
            var error_result = types.OwnedCallToolResult.init(self.allocator);
            defer error_result.deinit();
            error_result.isError = true;
            try error_result.addText(@errorName(err));
            try self.sendResult(req.id, error_result);
            return;
        };
        defer result.deinit();

        try self.sendResult(req.id, result);
    }

    fn handleListResources(self: *Server, req: jsonrpc.Request) !void {
        var resource_list: std.ArrayList(types.Resource) = .empty;
        defer resource_list.deinit(self.allocator);

        var it = self.resources.valueIterator();
        while (it.next()) |info| {
            try resource_list.append(self.allocator, info.resource);
        }

        const result = types.ListResourcesResult{
            .resources = resource_list.items,
        };

        try self.sendResult(req.id, result);
    }

    fn handleReadResource(self: *Server, req: jsonrpc.Request) !void {
        const params = req.params orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };

        const params_obj = switch (params) {
            .object => |o| o,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "Params must be object"));
                return;
            },
        };

        const uri_val = params_obj.get("uri") orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing uri"));
            return;
        };

        const uri = switch (uri_val) {
            .string => |s| s,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "Uri must be string"));
                return;
            },
        };

        const resource_info = self.resources.get(uri) orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown resource"));
            return;
        };

        var result = resource_info.handler(uri, self.allocator) catch |err| {
            try self.sendError(jsonrpc.Error.internalError(req.id, @errorName(err)));
            return;
        };
        defer result.deinit();

        try self.sendResult(req.id, result);
    }

    fn handleListPrompts(self: *Server, req: jsonrpc.Request) !void {
        var prompt_list: std.ArrayList(types.Prompt) = .empty;
        defer prompt_list.deinit(self.allocator);

        var it = self.prompts.valueIterator();
        while (it.next()) |info| {
            try prompt_list.append(self.allocator, info.prompt);
        }

        const result = types.ListPromptsResult{
            .prompts = prompt_list.items,
        };

        try self.sendResult(req.id, result);
    }

    fn handleGetPrompt(self: *Server, req: jsonrpc.Request) !void {
        const params = req.params orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };

        const params_obj = switch (params) {
            .object => |o| o,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "Params must be object"));
                return;
            },
        };

        const name_val = params_obj.get("name") orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Missing name"));
            return;
        };

        const name = switch (name_val) {
            .string => |s| s,
            else => {
                try self.sendError(jsonrpc.Error.invalidParams(req.id, "Name must be string"));
                return;
            },
        };

        const prompt_info = self.prompts.get(name) orelse {
            try self.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown prompt"));
            return;
        };

        const arguments_val = params_obj.get("arguments");
        const arguments: ?json.ObjectMap = if (arguments_val) |av| switch (av) {
            .object => |o| o,
            else => null,
        } else null;

        var result = prompt_info.handler(name, arguments, self.allocator) catch |err| {
            try self.sendError(jsonrpc.Error.internalError(req.id, @errorName(err)));
            return;
        };
        defer result.deinit();

        try self.sendResult(req.id, result);
    }

    fn getCapabilities(self: *Server) types.ServerCapabilities {
        return .{
            .tools = if (self.tools.count() > 0) .{} else null,
            .resources = if (self.resources.count() > 0) .{} else null,
            .prompts = if (self.prompts.count() > 0) .{} else null,
        };
    }

    fn sendResult(self: *Server, id: jsonrpc.RequestId, result: anytype) !void {
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

    fn sendError(self: *Server, err: jsonrpc.Error) !void {
        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var jws: json.Stringify = .{ .writer = &aw.writer };
        try err.jsonStringify(&jws);

        try aw.writer.flush();
        try self.transport.write(aw.written());
    }

    pub fn sendNotification(self: *Server, method: []const u8, params: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.allocator);
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
        const progress_token: types.ProgressParams.progressToken = switch (@TypeOf(token)) {
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

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n");

    const msg = try buffered.asTransport().read(std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);

    try server.handleMessage(msg);

    const output = buffered.getOutput();
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test-server") != null);
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

    try server.addTool(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = schema,
    }, struct {
        fn handler(_: []const u8, _: ?json.Value, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
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
