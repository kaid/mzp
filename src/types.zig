const std = @import("std");
const json = std.json;
const Io = std.Io;
const izo = @import("izomorph");

pub const LATEST_PROTOCOL_VERSION = "2025-11-25";
pub const DEFAULT_NEGOTIATED_VERSION = "2025-03-26";
/// Minimum protocolVersion that supports MCP `tasks/*` and task-augmented `tools/call`.
pub const TASKS_MIN_PROTOCOL_VERSION = "2025-11-25";

pub const Role = enum {
    user,
    assistant,

    pub const Mapper = izo.Mapper(Role, .{});
};

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(Implementation, .{
        .title = .{ .omit_null = true },
        .description = .{ .omit_null = true },
    });
};

pub const PromptsCapability = struct {
    list_changed: bool = false,

    pub const Mapper = izo.Mapper(PromptsCapability, .{
        .list_changed = .{ .alias = "listChanged", .omit_default = true },
    });
};

pub const ResourcesCapability = struct {
    subscribe: bool = false,
    list_changed: bool = false,

    pub const Mapper = izo.Mapper(ResourcesCapability, .{
        .subscribe = .{ .omit_default = true },
        .list_changed = .{ .alias = "listChanged", .omit_default = true },
    });
};

pub const ToolsCapability = struct {
    list_changed: bool = false,

    pub const Mapper = izo.Mapper(ToolsCapability, .{
        .list_changed = .{ .alias = "listChanged", .omit_default = true },
    });
};

pub const TasksRequestsCapability = struct {
    pub const ToolCall = struct {
        call: ?struct {} = null,

        pub const Mapper = izo.Mapper(ToolCall, .{
            .call = .{ .omit_null = true },
        });
    };

    tools: ?ToolCall = null,

    pub const Mapper = izo.Mapper(TasksRequestsCapability, .{
        .tools = .{ .omit_null = true, .nested = ToolCall.Mapper },
    });
};

pub const TasksCapability = struct {
    list: ?struct {} = null,
    cancel: ?struct {} = null,
    requests: ?TasksRequestsCapability = null,

    pub const Mapper = izo.Mapper(TasksCapability, .{
        .list = .{ .omit_null = true },
        .cancel = .{ .omit_null = true },
        .requests = .{ .omit_null = true, .nested = TasksRequestsCapability.Mapper },
    });
};

pub const LoggingCapability = struct {};

pub const CompletionsCapability = struct {};

pub const ServerCapabilities = struct {
    prompts: ?PromptsCapability = null,
    resources: ?ResourcesCapability = null,
    tools: ?ToolsCapability = null,
    tasks: ?TasksCapability = null,
    logging: ?LoggingCapability = null,
    completions: ?CompletionsCapability = null,
    experimental: ?json.Value = null,

    pub const Mapper = izo.Mapper(ServerCapabilities, .{
        .prompts = .{ .omit_null = true, .nested = PromptsCapability.Mapper },
        .resources = .{ .omit_null = true, .nested = ResourcesCapability.Mapper },
        .tools = .{ .omit_null = true, .nested = ToolsCapability.Mapper },
        .tasks = .{ .omit_null = true, .nested = TasksCapability.Mapper },
        .logging = .{ .omit_null = true },
        .completions = .{ .omit_null = true },
        .experimental = .{ .omit_null = true },
    });
};

pub const RootsCapability = struct {
    list_changed: bool = false,

    pub const Mapper = izo.Mapper(RootsCapability, .{
        .list_changed = .{ .alias = "listChanged", .omit_default = true },
    });
};

pub const SamplingCapability = struct {};
pub const ElicitationCapability = struct {};

pub const ClientCapabilities = struct {
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
    elicitation: ?ElicitationCapability = null,
    tasks: ?TasksCapability = null,
    experimental: ?json.Value = null,

    pub const Mapper = izo.Mapper(ClientCapabilities, .{
        .roots = .{ .omit_null = true, .nested = RootsCapability.Mapper },
        .sampling = .{ .omit_null = true },
        .elicitation = .{ .omit_null = true },
        .tasks = .{ .omit_null = true, .nested = TasksCapability.Mapper },
        .experimental = .{ .omit_null = true },
    });
};

pub const InitializeRequestParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: Implementation,

    pub const Mapper = izo.Mapper(InitializeRequestParams, .{
        .capabilities = .{ .nested = ClientCapabilities.Mapper },
        .clientInfo = .{ .nested = Implementation.Mapper },
    });
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: Implementation,
    instructions: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(InitializeResult, .{
        .capabilities = .{ .nested = ServerCapabilities.Mapper },
        .serverInfo = .{ .nested = Implementation.Mapper },
        .instructions = .{ .omit_null = true },
    });
};

pub const Root = struct {
    uri: []const u8,
    name: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(Root, .{
        .name = .{ .omit_null = true },
    });
};

/// Frees a root's strings (only valid if `uri` and `name` were allocator-owned).
pub fn freeRoot(allocator: std.mem.Allocator, root: Root) void {
    allocator.free(@constCast(root.uri));
    if (root.name) |n| allocator.free(@constCast(n));
}

pub const ListRootsResult = struct {
    roots: []const Root,

    pub const Mapper = izo.Mapper(ListRootsResult, .{
        .roots = .{ .element_mapper = Root.Mapper },
    });
};

/// Handler-safe, allocator-owned roots list result.
/// All slices inside this struct remain valid until `deinit()` is called.
pub const OwnedListRootsResult = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayList(Root) = .empty,

    pub fn init(allocator: std.mem.Allocator) OwnedListRootsResult {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OwnedListRootsResult) void {
        for (self.roots.items) |r| {
            freeRoot(self.allocator, r);
        }
        self.roots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addRoot(self: *OwnedListRootsResult, uri: []const u8, name: ?[]const u8) !void {
        const uri_duped = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_duped);

        const name_duped = if (name) |n| blk: {
            const d = try self.allocator.dupe(u8, n);
            break :blk d;
        } else null;
        errdefer if (name_duped) |n| self.allocator.free(n);

        try self.roots.append(self.allocator, .{ .uri = uri_duped, .name = name_duped });
    }

    /// Returns a ListRootsResult for serialization.
    pub fn toSerializable(self: OwnedListRootsResult) ListRootsResult {
        return .{ .roots = self.roots.items };
    }
};

const schema = @import("zjema").schema;

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: schema.JsonSchema,

    pub const Mapper = izo.Mapper(Tool, .{
        .description = .{ .omit_null = true },
    });

    pub fn deinit(_: Tool, _: std.mem.Allocator) void {
        // schema.JsonSchema is now composed of comptime constants
    }
};

pub const ListToolsResult = struct {
    tools: []const Tool,
    nextCursor: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(ListToolsResult, .{
        .tools = .{ .element_mapper = Tool.Mapper },
        .nextCursor = .{ .omit_null = true },
    });
};

pub fn stringifyJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const T = @TypeOf(value);
    // For json.Value, use standard library stringify
    if (T == json.Value) {
        return try std.json.Stringify.valueAlloc(allocator, value, .{});
    }
    // For other types, use izo.json.encode
    const Mapper = comptime izo.Mapper(T, .{});
    return @constCast(try izo.json.encode(allocator, value, Mapper, .{}));
}

pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const TextContentMapper = izo.Mapper(TextContent, .{});

pub const ImageContent = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,
};

pub const ImageContentMapper = izo.Mapper(ImageContent, .{});

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,

    pub const Mapper = izo.Mapper(ContentBlock, .{});
};

pub const CallToolResult = struct {
    content: []const ContentBlock,
    isError: bool = false,

    pub const Mapper = izo.Mapper(CallToolResult, .{
        .content = .{ .element_mapper = ContentBlock.Mapper },
        .isError = .{ .omit_default = true },
    });
};

fn freeContentBlock(allocator: std.mem.Allocator, block: ContentBlock) void {
    switch (block) {
        .text => |t| allocator.free(t.text),
        .image => |i| {
            allocator.free(i.data);
            allocator.free(i.mimeType);
        },
    }
}

/// Handler-safe, allocator-owned tool result.
/// All slices inside this struct remain valid until `deinit()` is called.
pub const OwnedCallToolResult = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(ContentBlock) = .empty,
    isError: bool = false,

    pub fn init(allocator: std.mem.Allocator) OwnedCallToolResult {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OwnedCallToolResult) void {
        for (self.content.items) |item| {
            freeContentBlock(self.allocator, item);
        }
        self.content.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addText(self: *OwnedCallToolResult, text: []const u8) !void {
        const duped = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(duped);
        try self.content.append(self.allocator, .{ .text = .{ .text = duped } });
    }

    pub fn addImage(self: *OwnedCallToolResult, data: []const u8, mimeType: []const u8) !void {
        const data_duped = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_duped);
        const mime_duped = try self.allocator.dupe(u8, mimeType);
        errdefer self.allocator.free(mime_duped);
        try self.content.append(self.allocator, .{ .image = .{ .data = data_duped, .mimeType = mime_duped } });
    }

    /// Returns a CallToolResult for serialization.
    pub fn toSerializable(self: OwnedCallToolResult) CallToolResult {
        return .{
            .content = self.content.items,
            .isError = self.isError,
        };
    }
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(Resource, .{
        .description = .{ .omit_null = true },
        .mimeType = .{ .omit_null = true },
    });
};

pub const ListResourcesResult = struct {
    resources: []const Resource,
    nextCursor: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(ListResourcesResult, .{
        .resources = .{ .element_mapper = Resource.Mapper },
        .nextCursor = .{ .omit_null = true },
    });
};

pub const TextResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: []const u8,

    pub const Mapper = izo.Mapper(TextResourceContents, .{
        .mimeType = .{ .omit_null = true },
    });
};

pub const BlobResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    blob: []const u8,

    pub const Mapper = izo.Mapper(BlobResourceContents, .{
        .mimeType = .{ .omit_null = true },
    });
};

pub const ResourceContents = union(enum) {
    text: TextResourceContents,
    blob: BlobResourceContents,

    pub const Mapper = izo.Mapper(ResourceContents, .{});
};

pub const ReadResourceResult = struct {
    contents: []const ResourceContents,

    pub const Mapper = izo.Mapper(ReadResourceResult, .{
        .contents = .{ .element_mapper = ResourceContents.Mapper },
    });
};

fn freeResourceContents(allocator: std.mem.Allocator, c: ResourceContents) void {
    switch (c) {
        .text => |t| {
            allocator.free(t.uri);
            if (t.mimeType) |m| allocator.free(m);
            allocator.free(t.text);
        },
        .blob => |b| {
            allocator.free(b.uri);
            if (b.mimeType) |m| allocator.free(m);
            allocator.free(b.blob);
        },
    }
}

/// Handler-safe, allocator-owned resource read result.
pub const OwnedReadResourceResult = struct {
    allocator: std.mem.Allocator,
    contents: std.ArrayList(ResourceContents) = .empty,

    pub fn init(allocator: std.mem.Allocator) OwnedReadResourceResult {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OwnedReadResourceResult) void {
        for (self.contents.items) |item| {
            freeResourceContents(self.allocator, item);
        }
        self.contents.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addText(self: *OwnedReadResourceResult, uri: []const u8, mimeType: ?[]const u8, text: []const u8) !void {
        const uri_duped = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_duped);
        const mime_duped: ?[]u8 = if (mimeType) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (mime_duped) |m| self.allocator.free(m);
        const text_duped = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_duped);

        try self.contents.append(self.allocator, .{
            .text = .{
                .uri = uri_duped,
                .mimeType = mime_duped,
                .text = text_duped,
            },
        });
    }

    pub fn addBlob(self: *OwnedReadResourceResult, uri: []const u8, mimeType: ?[]const u8, blob: []const u8) !void {
        const uri_duped = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_duped);
        const mime_duped: ?[]u8 = if (mimeType) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (mime_duped) |m| self.allocator.free(m);
        const blob_duped = try self.allocator.dupe(u8, blob);
        errdefer self.allocator.free(blob_duped);

        try self.contents.append(self.allocator, .{
            .blob = .{
                .uri = uri_duped,
                .mimeType = mime_duped,
                .blob = blob_duped,
            },
        });
    }

    /// Returns a ReadResourceResult for serialization.
    pub fn toSerializable(self: OwnedReadResourceResult) ReadResourceResult {
        return .{ .contents = self.contents.items };
    }
};

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: bool = false,

    pub const Mapper = izo.Mapper(PromptArgument, .{
        .description = .{ .omit_null = true },
        .required = .{ .omit_default = true },
    });
};

pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,

    pub const Mapper = izo.Mapper(Prompt, .{
        .description = .{ .omit_null = true },
        .arguments = .{ .omit_null = true, .element_mapper = PromptArgument.Mapper },
    });
};

pub const ListPromptsResult = struct {
    prompts: []const Prompt,
    nextCursor: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(ListPromptsResult, .{
        .prompts = .{ .element_mapper = Prompt.Mapper },
        .nextCursor = .{ .omit_null = true },
    });
};

pub const PromptMessage = struct {
    role: Role,
    content: ContentBlock,

    pub const Mapper = izo.Mapper(PromptMessage, .{});
};

pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,

    pub const Mapper = izo.Mapper(GetPromptResult, .{
        .description = .{ .omit_null = true },
        .messages = .{ .element_mapper = PromptMessage.Mapper },
    });
};

fn freePromptMessage(allocator: std.mem.Allocator, msg: PromptMessage) void {
    freeContentBlock(allocator, msg.content);
}

/// Handler-safe, allocator-owned prompt result.
pub const OwnedGetPromptResult = struct {
    allocator: std.mem.Allocator,
    description: ?[]u8 = null,
    messages: std.ArrayList(PromptMessage) = .empty,

    pub fn init(allocator: std.mem.Allocator) OwnedGetPromptResult {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OwnedGetPromptResult) void {
        if (self.description) |d| self.allocator.free(d);
        for (self.messages.items) |m| {
            freePromptMessage(self.allocator, m);
        }
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setDescription(self: *OwnedGetPromptResult, description: []const u8) !void {
        if (self.description) |d| self.allocator.free(d);
        self.description = try self.allocator.dupe(u8, description);
    }

    pub fn addTextMessage(self: *OwnedGetPromptResult, role: Role, text: []const u8) !void {
        const duped = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(duped);
        try self.messages.append(self.allocator, .{
            .role = role,
            .content = .{ .text = .{ .text = duped } },
        });
    }

    pub fn addImageMessage(self: *OwnedGetPromptResult, role: Role, data: []const u8, mimeType: []const u8) !void {
        const data_duped = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_duped);
        const mime_duped = try self.allocator.dupe(u8, mimeType);
        errdefer self.allocator.free(mime_duped);
        try self.messages.append(self.allocator, .{
            .role = role,
            .content = .{ .image = .{ .data = data_duped, .mimeType = mime_duped } },
        });
    }

    /// Returns a GetPromptResult for serialization.
    pub fn toSerializable(self: OwnedGetPromptResult) GetPromptResult {
        return .{
            .description = self.description,
            .messages = self.messages.items,
        };
    }
};

pub const LoggingLevel = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,

    pub const Mapper = izo.Mapper(LoggingLevel, .{});
};

pub const LoggingSetLevelParams = struct {
    level: LoggingLevel,

    pub const Mapper = izo.Mapper(LoggingSetLevelParams, .{});
};

pub const EmptyResult = struct {};

pub const EmptyResultMapper = izo.Mapper(EmptyResult, .{});

pub const LoggingMessageParams = struct {
    level: LoggingLevel,
    logger: ?[]const u8 = null,
    data: json.Value,

    pub const Mapper = izo.Mapper(LoggingMessageParams, .{
        .logger = .{ .omit_null = true },
    });
};

pub const ProgressToken = union(enum) {
    string: []const u8,
    number: i64,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !ProgressToken {
        _ = options;
        const token = try source.next();
        switch (token) {
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .allocated_string => |s| return .{ .string = s },
            .number => |n| return .{ .number = try std.fmt.parseInt(i64, n, 10) },
            else => return error.UnexpectedToken,
        }
    }
};

pub const ProgressParams = struct {
    progressToken: ProgressToken,
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(ProgressParams, .{
        .total = .{ .omit_null = true },
        .message = .{ .omit_null = true },
    });
};

pub const TaskStatus = enum {
    queued,
    running,
    input_required,
    completed,
    failed,
    cancelled,

    pub fn jsonStringify(self: TaskStatus, jws: *json.Stringify) !void {
        const s: []const u8 = switch (self) {
            .queued, .running => "working",
            .input_required => "input_required",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
        try jws.write(s);
    }
};

pub const Task = struct {
    id: []const u8,
    status: TaskStatus,
    createdAt: []const u8,
    updatedAt: []const u8,
    statusMessage: ?[]const u8 = null,
    ttl: ?u64 = null,
    pollInterval: ?u64 = null,

    pub const Mapper = izo.Mapper(Task, .{
        .id = .{ .alias = "taskId" },
        .updatedAt = .{ .alias = "lastUpdatedAt" },
        .statusMessage = .{ .omit_null = true },
        .pollInterval = .{ .omit_null = true },
    });
};

pub const CreateTaskResult = struct {
    task: Task,

    pub const Mapper = izo.Mapper(CreateTaskResult, .{
        .task = .{ .nested = Task.Mapper },
    });
};

pub const ListTasksResult = struct {
    tasks: []const Task,
    nextCursor: ?[]const u8 = null,

    pub const Mapper = izo.Mapper(ListTasksResult, .{
        .tasks = .{ .element_mapper = Task.Mapper },
        .nextCursor = .{ .omit_null = true },
    });
};

test "ServerCapabilities stringify" {
    const caps = ServerCapabilities{
        .tools = ToolsCapability{ .list_changed = true },
        .resources = ResourcesCapability{ .subscribe = true },
    };

    const json_str = try izo.json.encode(std.testing.allocator, caps, ServerCapabilities.Mapper, .{});
    defer std.testing.allocator.free(json_str);
    try std.testing.expect(json_str.len > 0);
}

test "TasksCapability stringify uses nested objects" {
    const caps = ServerCapabilities{
        .tasks = .{
            .list = .{},
            .cancel = .{},
            .requests = .{ .tools = .{ .call = .{} } },
        },
    };

    const json_str = try izo.json.encode(std.testing.allocator, caps, ServerCapabilities.Mapper, .{});
    defer std.testing.allocator.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"tasks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"requests\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"call\"") != null);
}

test "Task stringify uses taskId/lastUpdatedAt and includes ttl" {
    const task = Task{
        .id = "task-1",
        .status = .running,
        .createdAt = "2026-02-05T00:00:00Z",
        .updatedAt = "2026-02-05T00:00:01Z",
        .ttl = null,
        .pollInterval = 500,
    };

    const json_str = try izo.json.encode(std.testing.allocator, task, Task.Mapper, .{});
    defer std.testing.allocator.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"taskId\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"lastUpdatedAt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"ttl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"pollInterval\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"working\"") != null);
}

test "Task stringify omits pollInterval when null" {
    const task = Task{
        .id = "task-1",
        .status = .running,
        .createdAt = "2026-02-05T00:00:00Z",
        .updatedAt = "2026-02-05T00:00:01Z",
        .ttl = 60000,
        .pollInterval = null,
    };

    const json_str = try izo.json.encode(std.testing.allocator, task, Task.Mapper, .{});
    defer std.testing.allocator.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"pollInterval\"") == null);
}
