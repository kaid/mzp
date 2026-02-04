const std = @import("std");
const json = std.json;
const jsonrpc = @import("../../jsonrpc.zig");
const types = @import("../../types.zig");

pub const LegacyHandler = *const fn (
    uri: []const u8,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedReadResourceResult;

pub const HandlerWithUserData = *const fn (
    user_data: ?*anyopaque,
    uri: []const u8,
    allocator: std.mem.Allocator,
) anyerror!types.OwnedReadResourceResult;

pub const HandlerVariant = union(enum) {
    legacy: LegacyHandler,
    with_user_data: HandlerWithUserData,
};

pub const Capability = struct {
    allocator: std.mem.Allocator,
    default_user_data: ?*anyopaque,
    resources: std.StringHashMap(ResourceInfo),

    pub const ResourceInfo = struct {
        resource: types.Resource,
        handler: HandlerVariant,
        user_data: ?*anyopaque = null,
    };

    pub fn init(allocator: std.mem.Allocator, default_user_data: ?*anyopaque) Capability {
        return .{
            .allocator = allocator,
            .default_user_data = default_user_data,
            .resources = std.StringHashMap(ResourceInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Capability) void {
        self.resources.deinit();
        self.* = undefined;
    }

    pub fn count(self: *Capability) usize {
        return self.resources.count();
    }

    pub fn add(self: *Capability, resource: types.Resource, handler: LegacyHandler) !void {
        try self.resources.put(resource.uri, .{
            .resource = resource,
            .handler = .{ .legacy = handler },
        });
    }

    pub fn addWithUserData(
        self: *Capability,
        resource: types.Resource,
        handler: HandlerWithUserData,
        user_data: ?*anyopaque,
    ) !void {
        try self.resources.put(resource.uri, .{
            .resource = resource,
            .handler = .{ .with_user_data = handler },
            .user_data = user_data orelse self.default_user_data,
        });
    }

    pub fn handleList(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        var resource_list: std.ArrayList(types.Resource) = .empty;
        defer resource_list.deinit(self.allocator);

        var it = self.resources.valueIterator();
        while (it.next()) |info| {
            try resource_list.append(self.allocator, info.resource);
        }

        try server.sendResult(req.id, types.ListResourcesResult{
            .resources = resource_list.items,
        });
    }

    pub fn handleRead(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
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

        const uri_val = params_obj.get("uri") orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing uri"));
            return;
        };

        const uri = switch (uri_val) {
            .string => |s| s,
            else => {
                try server.sendError(jsonrpc.Error.invalidParams(req.id, "Uri must be string"));
                return;
            },
        };

        const resource_info = self.resources.get(uri) orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown resource"));
            return;
        };

        var result = switch (resource_info.handler) {
            .legacy => |h| h(uri, self.allocator),
            .with_user_data => |h| h(resource_info.user_data, uri, self.allocator),
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
