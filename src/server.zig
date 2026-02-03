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

pub const ToolHandlerWithUserData = *const fn (
    user_data: ?*anyopaque,
    name: []const u8,
    arguments: ?json.Value,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedCallToolResult;

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
    next_request_id: i64 = 1,
    user_data: ?*anyopaque = null,
    on_notification: ?NotificationHandler = null,

    tools: std.StringHashMap(ToolInfo),
    resources: std.StringHashMap(ResourceInfo),
    prompts: std.StringHashMap(PromptInfo),

    pub const ToolHandlerVariant = union(enum) {
        legacy: ToolHandler,
        with_user_data: ToolHandlerWithUserData,
    };

    pub const ResourceHandlerVariant = union(enum) {
        legacy: ResourceHandler,
        with_user_data: ResourceHandlerWithUserData,
    };

    pub const PromptHandlerVariant = union(enum) {
        legacy: PromptHandler,
        with_user_data: PromptHandlerWithUserData,
    };

    pub const ToolInfo = struct {
        tool: types.Tool,
        handler: ToolHandlerVariant,
        user_data: ?*anyopaque = null,
    };

    pub const ResourceInfo = struct {
        resource: types.Resource,
        handler: ResourceHandlerVariant,
        user_data: ?*anyopaque = null,
    };

    pub const PromptInfo = struct {
        prompt: types.Prompt,
        handler: PromptHandlerVariant,
        user_data: ?*anyopaque = null,
    };

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions, transport: *Transport) Server {
        return .{
            .allocator = allocator,
            .options = options,
            .transport = transport,
            .user_data = options.user_data,
            .on_notification = options.on_notification,
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
            .handler = .{ .legacy = handler },
        });
    }

    pub fn addToolWithUserData(
        self: *Server,
        tool: anytype,
        handler: ToolHandlerWithUserData,
        user_data: ?*anyopaque,
    ) !void {
        const T = @TypeOf(tool);

        if (!@hasField(T, "name")) @compileError("addToolWithUserData: tool must have a `name` field");
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
            @compileError("addToolWithUserData: tool must have `inputSchema` (any JSON-serializable value) or `inputSchemaJson` ([]const u8) field");
        };

        try self.tools.put(name, .{
            .tool = .{
                .name = name,
                .description = description,
                .inputSchemaJson = schema_json,
                .inputSchemaJsonOwned = true,
            },
            .handler = .{ .with_user_data = handler },
            .user_data = user_data orelse self.user_data,
        });
    }

    pub fn addResource(
        self: *Server,
        resource: types.Resource,
        handler: ResourceHandler,
    ) !void {
        try self.resources.put(resource.uri, .{
            .resource = resource,
            .handler = .{ .legacy = handler },
        });
    }

    pub fn addResourceWithUserData(
        self: *Server,
        resource: types.Resource,
        handler: ResourceHandlerWithUserData,
        user_data: ?*anyopaque,
    ) !void {
        try self.resources.put(resource.uri, .{
            .resource = resource,
            .handler = .{ .with_user_data = handler },
            .user_data = user_data orelse self.user_data,
        });
    }

    pub fn addPrompt(
        self: *Server,
        prompt: types.Prompt,
        handler: PromptHandler,
    ) !void {
        try self.prompts.put(prompt.name, .{
            .prompt = prompt,
            .handler = .{ .legacy = handler },
        });
    }

    pub fn addPromptWithUserData(
        self: *Server,
        prompt: types.Prompt,
        handler: PromptHandlerWithUserData,
        user_data: ?*anyopaque,
    ) !void {
        try self.prompts.put(prompt.name, .{
            .prompt = prompt,
            .handler = .{ .with_user_data = handler },
            .user_data = user_data orelse self.user_data,
        });
    }

    pub fn run(self: *Server) !void {
        while (true) {
            const msg = try self.transport.read(self.allocator) orelse break;
            defer jsonrpc.Message.freeMessage(self.allocator, msg);
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
        } else if (std.mem.eql(u8, notif.method, "notifications/roots/list_changed")) {
            // Client roots changed; callers can re-fetch via `roots/list`.
        }

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

        var result = switch (tool_info.handler) {
            .legacy => |h| h(name, arguments, self.allocator),
            .with_user_data => |h| h(tool_info.user_data, name, arguments, self.allocator),
        } catch |err| {
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

        var result = switch (resource_info.handler) {
            .legacy => |h| h(uri, self.allocator),
            .with_user_data => |h| h(resource_info.user_data, uri, self.allocator),
        } catch |err| {
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

        var result = switch (prompt_info.handler) {
            .legacy => |h| h(name, arguments, self.allocator),
            .with_user_data => |h| h(prompt_info.user_data, name, arguments, self.allocator),
        } catch |err| {
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

    fn getBool(obj: json.ObjectMap, key: []const u8) bool {
        const v = obj.get(key) orelse return false;
        return switch (v) {
            .bool => |b| b,
            else => false,
        };
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

test "Server tool handler with user_data" {
    var buffered = transport_mod.BufferedTransport.init(std.testing.allocator);
    defer buffered.deinit();

    var server = Server.init(
        std.testing.allocator,
        .{ .name = "test-server", .version = "1.0.0" },
        buffered.asTransport(),
    );
    defer server.deinit();

    const Ctx = struct { prefix: []const u8 };
    var ctx = Ctx{ .prefix = "pfx:" };

    try server.addToolWithUserData(.{
        .name = "echo",
        .description = "Echo",
        .inputSchema = .{ .type = "object" },
    }, struct {
        fn handler(user_data: ?*anyopaque, _: []const u8, _: ?json.Value, allocator: std.mem.Allocator) anyerror!types.OwnedCallToolResult {
            const c: *const Ctx = @ptrCast(@alignCast(user_data.?));
            var result = types.OwnedCallToolResult.init(allocator);
            try result.addText(c.prefix);
            return result;
        }
    }.handler, &ctx);

    try buffered.setInput("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}\n");

    const msg = try buffered.asTransport().read(std.testing.allocator) orelse unreachable;
    defer jsonrpc.Message.freeMessage(std.testing.allocator, msg);
    try server.handleMessage(msg);

    const output = buffered.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "pfx:") != null);
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
