const std = @import("std");
const jsonrpc = @import("../../jsonrpc.zig");
const types = @import("../../types.zig");

const tools_mod = @import("tools.zig");
const resources_mod = @import("resources.zig");
const prompts_mod = @import("prompts.zig");
const tasks_mod = @import("tasks.zig");

pub const Cascade = struct {
    tools: tools_mod.Capability,
    resources: resources_mod.Capability,
    prompts: prompts_mod.Capability,
    tasks: tasks_mod.Capability,

    pub fn init(
        allocator: std.mem.Allocator,
        default_user_data: ?*anyopaque,
        enable_tasks: bool,
        task_workers: usize,
    ) Cascade {
        return .{
            .tools = tools_mod.Capability.init(allocator, default_user_data),
            .resources = resources_mod.Capability.init(allocator, default_user_data),
            .prompts = prompts_mod.Capability.init(allocator, default_user_data),
            .tasks = tasks_mod.Capability.init(allocator, enable_tasks, task_workers),
        };
    }

    pub fn deinit(self: *Cascade) void {
        self.tasks.deinit();
        self.prompts.deinit();
        self.resources.deinit();
        self.tools.deinit();
        self.* = undefined;
    }

    pub fn advertise(self: *Cascade) types.ServerCapabilities {
        return .{
            .tools = if (self.tools.count() > 0) .{} else null,
            .resources = if (self.resources.count() > 0) .{} else null,
            .prompts = if (self.prompts.count() > 0) .{} else null,
            .tasks = if (self.tasks.enabled) .{
                .list = .{},
                .cancel = .{},
                .requests = .{ .tools = .{ .call = .{} } },
            } else null,
        };
    }

    pub fn handleRequest(self: *Cascade, server: anytype, req: jsonrpc.Request) !bool {
        if (std.mem.eql(u8, req.method, "tools/list")) {
            try self.tools.handleList(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "tools/call")) {
            try self.tools.handleCall(server, req, &self.tasks);
            return true;
        }
        if (std.mem.eql(u8, req.method, "resources/list")) {
            try self.resources.handleList(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "resources/read")) {
            try self.resources.handleRead(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "prompts/list")) {
            try self.prompts.handleList(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "prompts/get")) {
            try self.prompts.handleGet(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "tasks/list")) {
            try self.tasks.handleList(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "tasks/get")) {
            try self.tasks.handleGet(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "tasks/cancel")) {
            try self.tasks.handleCancel(server, req);
            return true;
        }
        if (std.mem.eql(u8, req.method, "tasks/result")) {
            try self.tasks.handleResult(server, req);
            return true;
        }

        return false;
    }

    pub fn handleNotification(self: *Cascade, server: anytype, notif: jsonrpc.Notification) !void {
        try self.tools.handleNotification(server, notif);
        try self.resources.handleNotification(server, notif);
        try self.prompts.handleNotification(server, notif);
        try self.tasks.handleNotification(server, notif);
    }
};
