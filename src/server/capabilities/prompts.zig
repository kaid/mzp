const std = @import("std");
const json = std.json;
const jsonrpc = @import("../../jsonrpc.zig");
const types = @import("../../types.zig");
const typed_codec = @import("../../serde/typed_codec.zig");

const RawHandlerWithUserData = *const fn (
    user_data: ?*anyopaque,
    name: []const u8,
    arguments: ?json.Value,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedGetPromptResult;

pub fn TypedHandlerWithUserData(comptime Args: type) type {
    return *const fn (
        user_data: ?*anyopaque,
        name: []const u8,
        arguments: ?Args,
        allocator: std.mem.Allocator,
    ) anyerror!types.OwnedGetPromptResult;
}

pub const Capability = struct {
    allocator: std.mem.Allocator,
    default_user_data: ?*anyopaque,
    prompts: std.StringHashMap(PromptInfo),

    pub const PromptInfo = struct {
        prompt: types.Prompt,
        handler: RawHandlerWithUserData,
        user_data: ?*anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, default_user_data: ?*anyopaque) Capability {
        return .{
            .allocator = allocator,
            .default_user_data = default_user_data,
            .prompts = std.StringHashMap(PromptInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Capability) void {
        self.prompts.deinit();
        self.* = undefined;
    }

    pub fn count(self: *Capability) usize {
        return self.prompts.count();
    }

    fn registerWithUserData(
        self: *Capability,
        prompt: types.Prompt,
        handler: RawHandlerWithUserData,
        user_data: ?*anyopaque,
    ) !void {
        try self.prompts.put(prompt.name, .{
            .prompt = prompt,
            .handler = handler,
            .user_data = user_data orelse self.default_user_data,
        });
    }

    pub fn addTyped(
        self: *Capability,
        prompt: types.Prompt,
        comptime ArgsMapper: type,
        comptime handler: TypedHandlerWithUserData(ArgsMapper.TargetType),
        user_data: ?*anyopaque,
    ) !void {
        const Args = ArgsMapper.TargetType;
        const Adapter = struct {
            fn bridge(
                bridge_user_data: ?*anyopaque,
                name: []const u8,
                arguments: ?json.Value,
                allocator: std.mem.Allocator,
            ) anyerror!types.OwnedGetPromptResult {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const aa = arena.allocator();

                const typed_args: ?Args = if (arguments) |raw_args|
                    try typed_codec.valueToTyped(aa, Args, ArgsMapper, raw_args)
                else
                    null;
                return try handler(bridge_user_data, name, typed_args, allocator);
            }
        };

        try self.registerWithUserData(prompt, Adapter.bridge, user_data);
    }

    pub fn handleList(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        var prompt_list: std.ArrayList(types.Prompt) = .empty;
        defer prompt_list.deinit(self.allocator);

        var it = self.prompts.valueIterator();
        while (it.next()) |info| {
            try prompt_list.append(self.allocator, info.prompt);
        }

        try server.sendResult(req.id, types.ListPromptsResult{
            .prompts = prompt_list.items,
        });
    }

    pub fn handleGet(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        const params = req.params orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const Params = struct {
            name: []const u8,
            arguments: ?json.Value = null,
        };
        const ParamsMapper = typed_codec.defaultMapper(Params);

        const parsed = typed_codec.valueToTyped(a, Params, ParamsMapper, params) catch {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Params must include string name"));
            return;
        };
        const name = parsed.name;

        const prompt_info = self.prompts.get(name) orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown prompt"));
            return;
        };

        const arguments = parsed.arguments;

        var result = prompt_info.handler(prompt_info.user_data, name, arguments, self.allocator) catch |err| {
            try server.sendError(jsonrpc.Error.internalError(req.id, @errorName(err)));
            return;
        };
        defer result.deinit();

        try server.sendResult(req.id, result.toSerializable());
    }

    pub fn handleNotification(self: *Capability, server: anytype, notif: jsonrpc.Notification) !void {
        _ = self;
        _ = server;
        _ = notif;
    }
};
