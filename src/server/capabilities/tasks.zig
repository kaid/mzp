const std = @import("std");
const json = std.json;
const jsonrpc = @import("../../jsonrpc.zig");
const types = @import("../../types.zig");
const common = @import("../common.zig");
const builtin = @import("builtin");
const typed_codec = @import("../../serde/typed_codec.zig");

pub extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *std.os.windows.FILETIME) callconv(.winapi) void;

pub const StatusNotifyFn = *const fn (ctx: *anyopaque, task: types.Task) void;

pub const StatusNotifier = struct {
    ctx: *anyopaque,
    send: StatusNotifyFn,
};

pub const Capability = struct {
    allocator: std.mem.Allocator,
    worker_allocator: ?std.mem.Allocator = null,
    enabled: bool,
    task_workers: usize,

    tasks_mutex: std.Thread.Mutex = .{},
    tasks: std.StringHashMap(*TaskRecord),
    task_order: std.ArrayList([]const u8) = .empty,
    next_task_seq: u64 = 1,

    jobs_mutex: std.Thread.Mutex = .{},
    jobs_cv: std.Thread.Condition = .{},
    jobs: std.ArrayList(*TaskJob) = .empty,
    workers: std.ArrayList(std.Thread) = .empty,
    workers_started: bool = false,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    status_notifier: ?StatusNotifier = null,

    pub const TaskRecord = struct {
        task: types.Task,
        cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        payload_json: ?[]u8 = null,
    };

    const TaskJob = struct {
        handler: common.ToolHandler,
        user_data: ?*anyopaque,
        tool_name: []u8,
        args_json: ?[]u8,
        meta: common.ToolCallMeta,
        task: *TaskRecord,
        progress_token_owned: ?[]u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, enabled: bool, task_workers: usize) Capability {
        return .{
            .allocator = allocator,
            .enabled = enabled,
            .task_workers = if (task_workers == 0) 1 else task_workers,
            .tasks = std.StringHashMap(*TaskRecord).init(allocator),
        };
    }

    pub fn setWorkerAllocator(self: *Capability, allocator: std.mem.Allocator) void {
        self.worker_allocator = allocator;
    }

    pub fn deinit(self: *Capability) void {
        self.stopWorkers();

        // Free queued jobs that never ran.
        self.jobs_mutex.lock();
        var pending = self.jobs;
        self.jobs = .empty;
        self.jobs_mutex.unlock();
        for (pending.items) |j| self.freeJob(j);
        pending.deinit(self.allocator);

        self.freeAllTasks();
        self.tasks.deinit();
        self.task_order.deinit(self.allocator);
        self.workers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setStatusNotifier(self: *Capability, notifier: StatusNotifier) void {
        self.status_notifier = notifier;
    }

    pub fn ensureWorkersStarted(self: *Capability) !void {
        if (!self.enabled) return;
        if (self.workers_started) return;

        self.shutting_down.store(false, .release);
        self.workers_started = true;

        var i: usize = 0;
        while (i < self.task_workers) : (i += 1) {
            const th = try std.Thread.spawn(.{}, workerMain, .{self});
            try self.workers.append(self.allocator, th);
        }
    }

    fn stopWorkers(self: *Capability) void {
        if (!self.workers_started) return;

        self.shutting_down.store(true, .release);
        self.jobs_cv.broadcast();

        for (self.workers.items) |th| th.join();
        self.workers.clearRetainingCapacity();
        self.workers_started = false;
    }

    fn workerMain(self: *Capability) void {
        while (true) {
            var job: ?*TaskJob = null;

            self.jobs_mutex.lock();
            while (self.jobs.items.len == 0 and !self.shutting_down.load(.acquire)) {
                self.jobs_cv.wait(&self.jobs_mutex);
            }
            if (self.shutting_down.load(.acquire) and self.jobs.items.len == 0) {
                self.jobs_mutex.unlock();
                break;
            }
            job = self.jobs.pop();
            self.jobs_mutex.unlock();

            const j = job.?;
            self.runJob(j);
            self.freeJob(j);
        }
    }

    fn runJob(self: *Capability, job: *TaskJob) void {
        const a = self.taskAllocator();
        const cancel = common.CancellationToken{ .cancelled = &job.task.cancelled };
        if (cancel.isCancelled()) {
            self.finalizeTaskCancelled(job.task) catch {};
            self.notifyStatus(self.snapshotTask(job.task));
            return;
        }

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();

        var args_val: ?json.Value = null;
        if (job.args_json) |s| {
            var parsed = json.parseFromSlice(json.Value, aa, s, .{}) catch {
                self.finalizeTaskWithPayload(job.task, .failed, "{\"content\":[],\"isError\":true}", "Invalid arguments JSON") catch {};
                self.notifyStatus(self.snapshotTask(job.task));
                return;
            };
            defer parsed.deinit();
            args_val = parsed.value;
        }

        var result = job.handler(job.user_data, job.tool_name, args_val, job.meta, cancel, a) catch |err| blk: {
            var error_result = types.OwnedCallToolResult.init(a);
            error_result.isError = true;
            error_result.addText(@errorName(err)) catch {};
            break :blk error_result;
        };
        defer result.deinit();

        const payload_json = types.stringifyJsonAlloc(a, result) catch {
            self.finalizeTaskCancelled(job.task) catch {};
            self.notifyStatus(self.snapshotTask(job.task));
            return;
        };
        defer a.free(payload_json);

        if (cancel.isCancelled()) {
            self.finalizeTaskCancelled(job.task) catch {};
            self.notifyStatus(self.snapshotTask(job.task));
            return;
        }

        const status: types.TaskStatus = if (result.isError) .failed else .completed;
        self.finalizeTaskWithPayload(job.task, status, payload_json, null) catch {};
        self.notifyStatus(self.snapshotTask(job.task));
    }

    fn notifyStatus(self: *Capability, task: types.Task) void {
        const n = self.status_notifier orelse return;
        n.send(n.ctx, task);
    }

    fn snapshotTask(self: *Capability, rec: *TaskRecord) types.Task {
        self.tasks_mutex.lock();
        const copy = rec.task;
        self.tasks_mutex.unlock();
        return copy;
    }

    fn freeJob(self: *Capability, job: *TaskJob) void {
        const a = self.taskAllocator();
        a.free(job.tool_name);
        if (job.args_json) |s| a.free(s);
        if (job.progress_token_owned) |s| a.free(s);
        a.destroy(job);
    }

    fn freeAllTasks(self: *Capability) void {
        self.tasks_mutex.lock();
        defer self.tasks_mutex.unlock();

        var it = self.tasks.valueIterator();
        while (it.next()) |rec_ptr| {
            freeTaskRecord(self, rec_ptr.*);
        }
        self.tasks.clearRetainingCapacity();
        self.task_order.clearRetainingCapacity();
    }

    pub const TaskParams = struct {
        ttl: ?u64 = null,
        pollInterval: ?u64 = null,
    };

    pub fn createTask(self: *Capability, params: TaskParams) !*TaskRecord {
        self.tasks_mutex.lock();
        defer self.tasks_mutex.unlock();

        const seq = self.next_task_seq;
        self.next_task_seq += 1;

        const a = self.taskAllocator();

        const id = try std.fmt.allocPrint(a, "task-{d}", .{seq});
        errdefer a.free(id);

        const created_at = try allocIsoTimestamp(a);
        errdefer a.free(created_at);
        const updated_at = try a.dupe(u8, created_at);
        errdefer a.free(updated_at);

        const rec = try a.create(TaskRecord);
        errdefer a.destroy(rec);

        rec.* = .{
            .task = .{
                .id = id,
                .status = .running,
                .createdAt = created_at,
                .updatedAt = updated_at,
                .ttl = params.ttl,
                .pollInterval = params.pollInterval,
            },
        };

        try self.tasks.put(rec.task.id, rec);
        try self.task_order.append(self.allocator, rec.task.id);

        return rec;
    }

    pub fn enqueueToolJob(
        self: *Capability,
        handler: common.ToolHandler,
        user_data: ?*anyopaque,
        tool_name: []const u8,
        arguments: ?json.Value,
        meta: common.ToolCallMeta,
        task: *TaskRecord,
    ) !void {
        const a = self.taskAllocator();

        var meta_copy = meta;
        var progress_token_owned: ?[]u8 = null;
        if (meta.progressToken) |pt| switch (pt) {
            .string => |s| {
                progress_token_owned = try a.dupe(u8, s);
                meta_copy.progressToken = .{ .string = progress_token_owned.? };
            },
            .number => {},
        };
        errdefer if (progress_token_owned) |s| a.free(s);

        const tool_name_duped = try a.dupe(u8, tool_name);
        errdefer a.free(tool_name_duped);

        const args_json: ?[]u8 = if (arguments) |av| try types.stringifyJsonAlloc(a, av) else null;
        errdefer if (args_json) |s| a.free(s);

        const job = try a.create(TaskJob);
        errdefer a.destroy(job);
        job.* = .{
            .handler = handler,
            .user_data = user_data,
            .tool_name = tool_name_duped,
            .args_json = args_json,
            .meta = meta_copy,
            .task = task,
            .progress_token_owned = progress_token_owned,
        };

        self.jobs_mutex.lock();
        errdefer self.jobs_mutex.unlock();
        try self.jobs.append(self.allocator, job);
        self.jobs_mutex.unlock();
        self.jobs_cv.signal();
    }

    pub fn handleList(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        if (!self.enabled) {
            try server.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
            return;
        }

        var cursor: ?usize = null;
        if (req.params) |p| {
            if (p != .null) {
                var arena = std.heap.ArenaAllocator.init(self.taskAllocator());
                defer arena.deinit();
                const a = arena.allocator();

                const Params = struct {
                    cursor: ?[]const u8 = null,
                };
                const ParamsMapper = typed_codec.defaultMapper(Params);
                const parsed = typed_codec.valueToTyped(a, Params, ParamsMapper, p) catch {
                    try server.sendError(jsonrpc.Error.invalidParams(req.id, "Params must be object"));
                    return;
                };
                if (parsed.cursor) |s| {
                    cursor = std.fmt.parseInt(usize, s, 10) catch {
                        try server.sendError(jsonrpc.Error.invalidParams(req.id, "Invalid cursor"));
                        return;
                    };
                }
            }
        }

        const start = cursor orelse 0;
        const page_size: usize = 100;

        var tasks_list: std.ArrayList(types.Task) = .empty;
        defer tasks_list.deinit(self.allocator);

        var next_cursor: ?[]const u8 = null;
        var next_buf: [32]u8 = undefined;

        var locked = true;
        self.tasks_mutex.lock();
        defer if (locked) self.tasks_mutex.unlock();

        if (start > self.task_order.items.len) {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Cursor out of range"));
            return;
        }

        const end = @min(start + page_size, self.task_order.items.len);
        var i: usize = start;
        while (i < end) : (i += 1) {
            const id = self.task_order.items[i];
            const rec = self.tasks.get(id) orelse continue;
            try tasks_list.append(self.allocator, rec.task);
        }

        if (end < self.task_order.items.len) {
            const s = try std.fmt.bufPrint(&next_buf, "{d}", .{end});
            next_cursor = s;
        }

        locked = false;
        self.tasks_mutex.unlock();

        try server.sendResult(req.id, types.ListTasksResult{
            .tasks = tasks_list.items,
            .nextCursor = next_cursor,
        });
    }

    pub fn handleGet(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        if (!self.enabled) {
            try server.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
            return;
        }

        const params = req.params orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };
        var arena = std.heap.ArenaAllocator.init(self.taskAllocator());
        defer arena.deinit();
        const id = getTaskIdParamValue(arena.allocator(), params) orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing task id"));
            return;
        };

        self.tasks_mutex.lock();
        const rec = self.tasks.get(id);
        self.tasks_mutex.unlock();

        if (rec == null) {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown task"));
            return;
        }

        // MCP tasks/get returns the task object directly.
        try server.sendResult(req.id, rec.?.task);
    }

    pub fn handleCancel(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        if (!self.enabled) {
            try server.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
            return;
        }

        const params = req.params orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };
        var arena = std.heap.ArenaAllocator.init(self.taskAllocator());
        defer arena.deinit();
        const id = getTaskIdParamValue(arena.allocator(), params) orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing task id"));
            return;
        };

        self.tasks_mutex.lock();
        const rec = self.tasks.get(id) orelse {
            self.tasks_mutex.unlock();
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown task"));
            return;
        };

        rec.cancelled.store(true, .release);

        const was_terminal = rec.task.status == .completed or rec.task.status == .failed or rec.task.status == .cancelled;
        if (!was_terminal) {
            const a = self.taskAllocator();
            try setTaskStatusLocked(a, rec, .cancelled, "Cancelled");
            if (rec.payload_json == null) {
                var cancel_result = types.OwnedCallToolResult.init(a);
                defer cancel_result.deinit();
                cancel_result.isError = true;
                try cancel_result.addText("Cancelled");
                rec.payload_json = try types.stringifyJsonAlloc(a, cancel_result);
            }
        }
        const task_copy = rec.task;
        self.tasks_mutex.unlock();

        if (!was_terminal) {
            try server.sendNotification("notifications/tasks/status", task_copy);
        }
        // MCP tasks/cancel returns the task object directly.
        try server.sendResult(req.id, task_copy);
    }

    pub fn handleResult(self: *Capability, server: anytype, req: jsonrpc.Request) !void {
        if (!self.enabled) {
            try server.sendError(jsonrpc.Error.methodNotFound(req.id, req.method));
            return;
        }

        const params = req.params orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing params"));
            return;
        };
        var params_arena = std.heap.ArenaAllocator.init(self.taskAllocator());
        defer params_arena.deinit();
        const id = getTaskIdParamValue(params_arena.allocator(), params) orelse {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Missing task id"));
            return;
        };

        var payload: ?[]const u8 = null;
        var task_id: ?[]const u8 = null;
        var status: ?types.TaskStatus = null;

        self.tasks_mutex.lock();
        if (self.tasks.get(id)) |rec| {
            payload = rec.payload_json;
            task_id = rec.task.id;
            status = rec.task.status;
        }
        self.tasks_mutex.unlock();

        if (payload == null or task_id == null or status == null) {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Unknown task"));
            return;
        }

        const st = status.?;
        const terminal = st == .completed or st == .failed or st == .cancelled;
        if (!terminal) {
            try server.sendError(jsonrpc.Error.invalidParams(req.id, "Task not complete"));
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.taskAllocator());
        defer arena.deinit();
        const a = arena.allocator();

        var parsed = try json.parseFromSlice(json.Value, a, payload.?, .{});
        defer parsed.deinit();

        var value = parsed.value;
        if (value == .object) {
            var obj_map = value.object;

            var related = json.ObjectMap.init(a);
            try related.put("taskId", .{ .string = task_id.? });

            var meta_obj = if (obj_map.get("_meta")) |mv| switch (mv) {
                .object => |o| o,
                else => json.ObjectMap.init(a),
            } else json.ObjectMap.init(a);

            try meta_obj.put("io.modelcontextprotocol/related-task", .{ .object = related });
            try obj_map.put("_meta", .{ .object = meta_obj });

            value = .{ .object = obj_map };
        }

        const Wrapper = struct {
            value: json.Value,
            pub fn jsonStringify(self_: @This(), jws: *json.Stringify) !void {
                try jws.write(self_.value);
            }
        };

        try server.sendResult(req.id, Wrapper{ .value = value });
    }

    pub fn finalizeTaskWithPayload(
        self: *Capability,
        rec: *TaskRecord,
        status: types.TaskStatus,
        payload_json: []const u8,
        status_message: ?[]const u8,
    ) !void {
        self.tasks_mutex.lock();
        defer self.tasks_mutex.unlock();

        if (rec.cancelled.load(.acquire)) return;

        const a = self.taskAllocator();
        if (rec.payload_json) |p| a.free(p);
        rec.payload_json = try a.dupe(u8, payload_json);

        try setTaskStatusLocked(a, rec, status, status_message);
    }

    pub fn finalizeTaskCancelled(self: *Capability, rec: *TaskRecord) !void {
        self.tasks_mutex.lock();
        errdefer self.tasks_mutex.unlock();
        rec.cancelled.store(true, .release);

        if (rec.task.status != .cancelled) {
            const a = self.taskAllocator();
            try setTaskStatusLocked(a, rec, .cancelled, "Cancelled");
        }

        if (rec.payload_json == null) {
            const a = self.taskAllocator();
            var cancel_result = types.OwnedCallToolResult.init(a);
            defer cancel_result.deinit();
            cancel_result.isError = true;
            try cancel_result.addText("Cancelled");
            rec.payload_json = try types.stringifyJsonAlloc(a, cancel_result);
        }

        self.tasks_mutex.unlock();
    }

    pub fn handleNotification(self: *Capability, server: anytype, notif: jsonrpc.Notification) !void {
        _ = self;
        _ = server;
        _ = notif;
    }

    fn taskAllocator(self: *Capability) std.mem.Allocator {
        return self.worker_allocator orelse self.allocator;
    }
};

pub fn parseTaskMetadataValue(task_val: ?json.Value) !?Capability.TaskParams {
    const tv = task_val orelse return null;
    if (tv == .null) return null;
    if (tv != .object) return error.InvalidTaskMetadata;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const WireTaskMetadata = struct {
        ttl: ?u64 = null,
        pollInterval: ?u64 = null,
    };
    const WireTaskMetadataMapper = typed_codec.defaultMapper(WireTaskMetadata);

    const decoded = typed_codec.valueToTyped(a, WireTaskMetadata, WireTaskMetadataMapper, tv) catch {
        return error.InvalidTaskMetadata;
    };

    return .{
        .ttl = decoded.ttl,
        .pollInterval = decoded.pollInterval,
    };
}

fn getTaskIdParamValue(allocator: std.mem.Allocator, params: json.Value) ?[]const u8 {
    const Params = struct {
        id: ?[]const u8 = null,
        taskId: ?[]const u8 = null,
    };
    const ParamsMapper = typed_codec.defaultMapper(Params);
    const parsed = typed_codec.valueToTyped(allocator, Params, ParamsMapper, params) catch return null;
    if (parsed.id) |id| return id;
    return parsed.taskId;
}

fn allocIsoTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const now: u64 = switch (builtin.os.tag) {
        .windows => blk: {
            const windows = std.os.windows;
            var ft: windows.FILETIME = undefined;
            GetSystemTimeAsFileTime(&ft);
            const secs_i: i64 = windows.fileTimeToNanoSeconds(ft).toSeconds();
            break :blk if (secs_i < 0) 0 else @as(u64, @intCast(secs_i));
        },
        else => blk: {
            const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
            const sec_i = ts.sec;
            break :blk if (sec_i < 0) 0 else @as(u64, @intCast(sec_i));
        },
    };
    const es = std.time.epoch.EpochSeconds{ .secs = now };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(
        &buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            yd.year,
            md.month.numeric(),
            @as(u32, md.day_index) + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        },
    );
    return try allocator.dupe(u8, s);
}

fn freeTaskRecord(self: *Capability, rec: *Capability.TaskRecord) void {
    const a = self.taskAllocator();
    a.free(@constCast(rec.task.id));
    a.free(@constCast(rec.task.createdAt));
    a.free(@constCast(rec.task.updatedAt));
    if (rec.task.statusMessage) |m| a.free(@constCast(m));
    if (rec.payload_json) |p| a.free(p);
    a.destroy(rec);
}

fn setTaskStatusLocked(allocator: std.mem.Allocator, rec: *Capability.TaskRecord, status: types.TaskStatus, status_message: ?[]const u8) !void {
    rec.task.status = status;

    const new_updated = try allocIsoTimestamp(allocator);
    allocator.free(@constCast(rec.task.updatedAt));
    rec.task.updatedAt = new_updated;

    if (rec.task.statusMessage) |m| allocator.free(@constCast(m));
    rec.task.statusMessage = if (status_message) |m| try allocator.dupe(u8, m) else null;
}
