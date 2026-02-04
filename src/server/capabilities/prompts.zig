const std = @import("std");
const json = std.json;
const jsonrpc = @import("../../jsonrpc.zig");
const types = @import("../../types.zig");

pub const LegacyHandler = *const fn (
    name: []const u8,
    arguments: ?json.ObjectMap,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedGetPromptResult;

pub const HandlerWithUserData = *const fn (
    user_data: ?*anyopaque,
    name: []const u8,
    arguments: ?json.ObjectMap,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedGetPromptResult;

pub const HandlerVariant = union(enum) {
    legacy: LegacyHandler,
    with_user_data: HandlerWithUserData,
};

pub const Capability = struct {
    allocator: std.mem.Allocator,
    default_user_data: ?*anyopaque,
    prompts: std.StringHashMap(PromptInfo),

    pub const PromptInfo = struct {
        prompt: types.Prompt,
        handler: HandlerVariant,
        user_data: ?*anyopaque = null,
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

    pub fn add(self: *Capability, prompt: types.Prompt, handler: LegacyHandler) !void {
        try self.prompts.put(prompt.name, .{
            .prompt = prompt,
            .handler = .{ .legacy = handler },
        });
    }

    pub fn addWithUserData(
        self: *Capability,
        prompt: types.Prompt,
        handler: HandlerWithUserData,
        user_data: ?*anyopaque,
    ) !void {
        try self.prompts.put(prompt.name, .{
            .prompt = prompt,
            .handler = .{ .with_user_data = handler },
            .user_data = user_data orelse self.default_user_data,
        });
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

        const params_obj = switch (params) {
            .object => |o| o,
            else => {
                try server.sendError(jsonrpc.Error.invalidParams(req.id, "Params must be object"));
                return;
            },
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

        const prompt_info = self.prompts.get(name) orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown prompt"));
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
            try server.sendError(jsonrpc.Error.internalError(req.id, @errorName(err)));
            return;
        };
        defer result.deinit();

        try server.sendResult(req.id, result);
    }

    pub fn handleNotification(self: *Capability, server: anytype, notif: jsonrpc.Notification) !void {
        _ = self;
        _ = server;
        _ = notif;
    }
};
