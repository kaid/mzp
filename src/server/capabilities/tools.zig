const std = @import("std");
const json = std.json;
const jsonrpc = @import("../../jsonrpc.zig");
const types = @import("../../types.zig");
const common = @import("../common.zig");
const cancellation_mod = @import("../cancellation.zig");
const tasks_mod = @import("tasks.zig");
const typed_codec = @import("../../serde/typed_codec.zig");

pub const Capability = struct {
    allocator: std.mem.Allocator,
    default_user_data: ?*anyopaque,
    tools: std.StringHashMap(ToolInfo),

    pub const ToolInfo = struct {
        tool: types.Tool,
        handler: common.ToolHandler,
        user_data: ?*anyopaque = null,
    };

    pub fn init(allocator: std.mem.Allocator, default_user_data: ?*anyopaque) Capability {
        return .{
            .allocator = allocator,
            .default_user_data = default_user_data,
            .tools = std.StringHashMap(ToolInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Capability) void {
        var it = self.tools.valueIterator();
        while (it.next()) |info| {
            info.tool.deinit(self.allocator);
        }
        self.tools.deinit();
        self.* = undefined;
    }

    pub fn count(self: *Capability) usize {
        return self.tools.count();
    }

    pub fn add(self: *Capability, tool: anytype, handler: common.ToolHandler) !void {
        return self.addWithUserData(tool, handler, null);
    }

    pub fn TypedToolHandler(comptime Args: type) type {
        return *const fn (
            user_data: ?*anyopaque,
            name: []const u8,
            arguments: ?Args,
            meta: common.ToolCallMeta,
            cancel: common.CancellationToken,
            allocator: std.mem.Allocator,
        ) anyerror!types.OwnedCallToolResult;
    }

    pub fn addTyped(
        self: *Capability,
        tool: anytype,
        comptime Args: type,
        comptime ArgsMapper: type,
        comptime handler: TypedToolHandler(Args),
    ) !void {
        return self.addTypedWithUserData(tool, Args, ArgsMapper, handler, null);
    }

    pub fn addTypedWithUserData(
        self: *Capability,
        tool: anytype,
        comptime Args: type,
        comptime ArgsMapper: type,
        comptime handler: TypedToolHandler(Args),
        user_data: ?*anyopaque,
    ) !void {
        const Adapter = struct {
            fn bridge(
                bridge_user_data: ?*anyopaque,
                name: []const u8,
                arguments: ?json.Value,
                meta: common.ToolCallMeta,
                cancel: common.CancellationToken,
                allocator: std.mem.Allocator,
            ) anyerror!types.OwnedCallToolResult {
                const typed_args: ?Args = if (arguments) |raw_args|
                    try typed_codec.valueToTyped(allocator, Args, ArgsMapper, raw_args)
                else
                    null;
                return try handler(bridge_user_data, name, typed_args, meta, cancel, allocator);
            }
        };

        try self.addWithUserData(tool, Adapter.bridge, user_data);
    }

    pub fn addWithUserData(
        self: *Capability,
        tool: anytype,
        handler: common.ToolHandler,
        user_data: ?*anyopaque,
    ) !void {
        const T = @TypeOf(tool);

        if (!@hasField(T, "name")) @compileError("tools.add: tool must have a `name` field");
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
            @compileError("tools.add: tool must have `inputSchema` (any JSON-serializable value) or `inputSchemaJson` ([]const u8) field");
        };

        try self.tools.put(name, .{
            .tool = .{
                .name = name,
                .description = description,
                .inputSchemaJson = schema_json,
                .inputSchemaJsonOwned = true,
            },
            .handler = handler,
            .user_data = user_data orelse self.default_user_data,
        });
    }

    pub fn handleList(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        var tool_list: std.ArrayList(types.Tool) = .empty;
        defer tool_list.deinit(self.allocator);

        var it = self.tools.valueIterator();
        while (it.next()) |info| {
            try tool_list.append(self.allocator, info.tool);
        }

        try server.sendResult(req.id, types.ListToolsResult{
            .tools = tool_list.items,
        });
    }

    pub fn handleCall(
        self: *Capability,
        server: anytype,
        req: jsonrpc.Request,
        tasks: *tasks_mod.Capability,
    ) !void {
        const params = req.params orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };
        const params_obj = switch (params) {
            .object => |o| o,
            else => {
                try server.sendError(jsonrpc.Error.invalidParams(req.id, "Params must be object"));
                return;
            },
        };

        const task_md = tasks_mod.parseTaskMetadataValue(params_obj.get("task")) catch {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Invalid task metadata"));
            return;
        };

        const name_val = params_obj.get("name") orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing name"));
            return;
        };
        const name = switch (name_val) {
            .string => |s| s,
            else => {
                try server.sendError(jsonrpc.Error.invalidParams(req.id, "Name must be string"));
                return;
            },
        };

        const tool_info = self.tools.get(name) orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown tool"));
            return;
        };

        const arguments = params_obj.get("arguments");

        var meta = parseToolCallMeta(params_obj.get("_meta"));
        meta.task = task_md;

        // tasks mode: only used when tasks are enabled and the client provided params.task.
        if (tasks.enabled and task_md != null) {
            try tasks.ensureWorkersStarted();
            const task_rec = try tasks.createTask(task_md.?);
            const created_task = task_rec.task;

            try server.sendResult(req.id, types.CreateTaskResult{ .task = created_task });
            try server.sendNotification("notifications/tasks/status", created_task);

            try tasks.enqueueToolJob(
                tool_info.handler,
                tool_info.user_data,
                name,
                arguments,
                meta,
                task_rec,
            );
            return;
        }

        // synchronous mode: tasks are disabled or the client did not provide params.task.
        var active: @TypeOf(server.*).ActiveRequest = .{ .id = req.id };
        cancellation_mod.registerActiveRequest(server, &active);
        defer cancellation_mod.unregisterActiveRequest(server, &active);

        const cancel = common.CancellationToken{ .cancelled = &active.cancelled };
        const a = server.getAllocator();

        var result = tool_info.handler(tool_info.user_data, name, arguments, meta, cancel, a) catch |err| blk: {
            var error_result = types.OwnedCallToolResult.init(a);
            error_result.isError = true;
            error_result.addText(@errorName(err)) catch {};
            break :blk error_result;
        };
        defer result.deinit();

        try server.sendResult(req.id, result);
    }

    pub fn handleNotification(self: *Capability, server: anytype, notif: jsonrpc.Notification) !void {
        _ = self;
        _ = server;
        _ = notif;
    }

    fn parseToolCallMeta(meta_val: ?json.Value) common.ToolCallMeta {
        const meta_obj = switch (meta_val orelse return .{}) {
            .object => |o| o,
            else => return .{},
        };

        const pt_val = meta_obj.get("progressToken") orelse return .{};
        const progress_token: ?types.ProgressToken = switch (pt_val) {
            .string => |s| .{ .string = s },
            .integer => |n| .{ .number = n },
            .number_string => |s| blk: {
                const parsed = std.fmt.parseInt(i64, s, 10) catch break :blk null;
                break :blk .{ .number = parsed };
            },
            else => null,
        };

        return .{ .progressToken = progress_token };
    }
};
