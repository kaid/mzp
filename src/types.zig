const std = @import("std");
const json = std.json;

pub const LATEST_PROTOCOL_VERSION = "2025-11-25";
pub const DEFAULT_NEGOTIATED_VERSION = "2025-03-26";

pub const Role = enum {
    user,
    assistant,

    pub fn jsonStringify(self: Role, jws: *json.Stringify) !void {
        try jws.write(@tagName(self));
    }
};

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,

    pub fn jsonStringify(self: Implementation, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("version");
        try jws.write(self.version);
        if (self.title) |t| {
            try jws.objectField("title");
            try jws.write(t);
        }
        if (self.description) |d| {
            try jws.objectField("description");
            try jws.write(d);
        }
        try jws.endObject();
    }
};

pub const PromptsCapability = struct {
    list_changed: bool = false,
};

pub const ResourcesCapability = struct {
    subscribe: bool = false,
    list_changed: bool = false,
};

pub const ToolsCapability = struct {
    list_changed: bool = false,
};

pub const LoggingCapability = struct {};

pub const CompletionsCapability = struct {};

pub const ServerCapabilities = struct {
    prompts: ?PromptsCapability = null,
    resources: ?ResourcesCapability = null,
    tools: ?ToolsCapability = null,
    logging: ?LoggingCapability = null,
    completions: ?CompletionsCapability = null,
    experimental: ?json.Value = null,

    pub fn jsonStringify(self: ServerCapabilities, jws: *json.Stringify) !void {
        try jws.beginObject();
        if (self.prompts) |p| {
            try jws.objectField("prompts");
            try jws.beginObject();
            if (p.list_changed) {
                try jws.objectField("listChanged");
                try jws.write(true);
            }
            try jws.endObject();
        }
        if (self.resources) |r| {
            try jws.objectField("resources");
            try jws.beginObject();
            if (r.subscribe) {
                try jws.objectField("subscribe");
                try jws.write(true);
            }
            if (r.list_changed) {
                try jws.objectField("listChanged");
                try jws.write(true);
            }
            try jws.endObject();
        }
        if (self.tools) |t| {
            try jws.objectField("tools");
            try jws.beginObject();
            if (t.list_changed) {
                try jws.objectField("listChanged");
                try jws.write(true);
            }
            try jws.endObject();
        }
        if (self.logging != null) {
            try jws.objectField("logging");
            try jws.beginObject();
            try jws.endObject();
        }
        if (self.completions != null) {
            try jws.objectField("completions");
            try jws.beginObject();
            try jws.endObject();
        }
        if (self.experimental) |e| {
            try jws.objectField("experimental");
            try jws.write(e);
        }
        try jws.endObject();
    }
};

pub const RootsCapability = struct {
    list_changed: bool = false,
};

pub const SamplingCapability = struct {};

pub const ElicitationCapability = struct {};

pub const ClientCapabilities = struct {
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
    elicitation: ?ElicitationCapability = null,
    experimental: ?json.Value = null,
};

pub const InitializeRequestParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: Implementation,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: Implementation,
    instructions: ?[]const u8 = null,

    pub fn jsonStringify(self: InitializeResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("protocolVersion");
        try jws.write(self.protocolVersion);
        try jws.objectField("capabilities");
        try self.capabilities.jsonStringify(jws);
        try jws.objectField("serverInfo");
        try self.serverInfo.jsonStringify(jws);
        if (self.instructions) |i| {
            try jws.objectField("instructions");
            try jws.write(i);
        }
        try jws.endObject();
    }
};

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: json.Value,

    pub fn jsonStringify(self: Tool, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        if (self.description) |d| {
            try jws.objectField("description");
            try jws.write(d);
        }
        try jws.objectField("inputSchema");
        try jws.write(self.inputSchema);
        try jws.endObject();
    }
};

pub const ListToolsResult = struct {
    tools: []const Tool,
    nextCursor: ?[]const u8 = null,

    pub fn jsonStringify(self: ListToolsResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("tools");
        try jws.beginArray();
        for (self.tools) |tool| {
            try tool.jsonStringify(jws);
        }
        try jws.endArray();
        if (self.nextCursor) |c| {
            try jws.objectField("nextCursor");
            try jws.write(c);
        }
        try jws.endObject();
    }
};

pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,

    pub fn jsonStringify(self: TextContent, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write(self.type);
        try jws.objectField("text");
        try jws.write(self.text);
        try jws.endObject();
    }
};

pub const ImageContent = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,

    pub fn jsonStringify(self: ImageContent, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write(self.type);
        try jws.objectField("data");
        try jws.write(self.data);
        try jws.objectField("mimeType");
        try jws.write(self.mimeType);
        try jws.endObject();
    }
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,

    pub fn jsonStringify(self: ContentBlock, jws: *json.Stringify) !void {
        switch (self) {
            .text => |t| try t.jsonStringify(jws),
            .image => |i| try i.jsonStringify(jws),
        }
    }
};

pub const CallToolResult = struct {
    content: []const ContentBlock,
    isError: bool = false,

    pub fn jsonStringify(self: CallToolResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("content");
        try jws.beginArray();
        for (self.content) |c| {
            try c.jsonStringify(jws);
        }
        try jws.endArray();
        if (self.isError) {
            try jws.objectField("isError");
            try jws.write(true);
        }
        try jws.endObject();
    }
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

    pub fn jsonStringify(self: OwnedCallToolResult, jws: *json.Stringify) !void {
        const view = CallToolResult{
            .content = self.content.items,
            .isError = self.isError,
        };
        try view.jsonStringify(jws);
    }
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,

    pub fn jsonStringify(self: Resource, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("uri");
        try jws.write(self.uri);
        try jws.objectField("name");
        try jws.write(self.name);
        if (self.description) |d| {
            try jws.objectField("description");
            try jws.write(d);
        }
        if (self.mimeType) |m| {
            try jws.objectField("mimeType");
            try jws.write(m);
        }
        try jws.endObject();
    }
};

pub const ListResourcesResult = struct {
    resources: []const Resource,
    nextCursor: ?[]const u8 = null,

    pub fn jsonStringify(self: ListResourcesResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("resources");
        try jws.beginArray();
        for (self.resources) |r| {
            try r.jsonStringify(jws);
        }
        try jws.endArray();
        if (self.nextCursor) |c| {
            try jws.objectField("nextCursor");
            try jws.write(c);
        }
        try jws.endObject();
    }
};

pub const TextResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: []const u8,

    pub fn jsonStringify(self: TextResourceContents, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("uri");
        try jws.write(self.uri);
        if (self.mimeType) |m| {
            try jws.objectField("mimeType");
            try jws.write(m);
        }
        try jws.objectField("text");
        try jws.write(self.text);
        try jws.endObject();
    }
};

pub const BlobResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    blob: []const u8,

    pub fn jsonStringify(self: BlobResourceContents, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("uri");
        try jws.write(self.uri);
        if (self.mimeType) |m| {
            try jws.objectField("mimeType");
            try jws.write(m);
        }
        try jws.objectField("blob");
        try jws.write(self.blob);
        try jws.endObject();
    }
};

pub const ResourceContents = union(enum) {
    text: TextResourceContents,
    blob: BlobResourceContents,

    pub fn jsonStringify(self: ResourceContents, jws: *json.Stringify) !void {
        switch (self) {
            .text => |t| try t.jsonStringify(jws),
            .blob => |b| try b.jsonStringify(jws),
        }
    }
};

pub const ReadResourceResult = struct {
    contents: []const ResourceContents,

    pub fn jsonStringify(self: ReadResourceResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("contents");
        try jws.beginArray();
        for (self.contents) |c| {
            try c.jsonStringify(jws);
        }
        try jws.endArray();
        try jws.endObject();
    }
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

    pub fn jsonStringify(self: OwnedReadResourceResult, jws: *json.Stringify) !void {
        const view = ReadResourceResult{ .contents = self.contents.items };
        try view.jsonStringify(jws);
    }
};

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: bool = false,

    pub fn jsonStringify(self: PromptArgument, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        if (self.description) |d| {
            try jws.objectField("description");
            try jws.write(d);
        }
        if (self.required) {
            try jws.objectField("required");
            try jws.write(true);
        }
        try jws.endObject();
    }
};

pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,

    pub fn jsonStringify(self: Prompt, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        if (self.description) |d| {
            try jws.objectField("description");
            try jws.write(d);
        }
        if (self.arguments) |args| {
            try jws.objectField("arguments");
            try jws.beginArray();
            for (args) |a| {
                try a.jsonStringify(jws);
            }
            try jws.endArray();
        }
        try jws.endObject();
    }
};

pub const ListPromptsResult = struct {
    prompts: []const Prompt,
    nextCursor: ?[]const u8 = null,

    pub fn jsonStringify(self: ListPromptsResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("prompts");
        try jws.beginArray();
        for (self.prompts) |p| {
            try p.jsonStringify(jws);
        }
        try jws.endArray();
        if (self.nextCursor) |c| {
            try jws.objectField("nextCursor");
            try jws.write(c);
        }
        try jws.endObject();
    }
};

pub const PromptMessage = struct {
    role: Role,
    content: ContentBlock,

    pub fn jsonStringify(self: PromptMessage, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("role");
        try self.role.jsonStringify(jws);
        try jws.objectField("content");
        try self.content.jsonStringify(jws);
        try jws.endObject();
    }
};

pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,

    pub fn jsonStringify(self: GetPromptResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        if (self.description) |d| {
            try jws.objectField("description");
            try jws.write(d);
        }
        try jws.objectField("messages");
        try jws.beginArray();
        for (self.messages) |m| {
            try m.jsonStringify(jws);
        }
        try jws.endArray();
        try jws.endObject();
    }
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

    pub fn jsonStringify(self: OwnedGetPromptResult, jws: *json.Stringify) !void {
        const view = GetPromptResult{
            .description = self.description,
            .messages = self.messages.items,
        };
        try view.jsonStringify(jws);
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

    pub fn jsonStringify(self: LoggingLevel, jws: *json.Stringify) !void {
        try jws.write(@tagName(self));
    }
};

pub const EmptyResult = struct {
    pub fn jsonStringify(_: EmptyResult, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.endObject();
    }
};

pub const LoggingMessageParams = struct {
    level: LoggingLevel,
    logger: ?[]const u8 = null,
    data: json.Value,

    pub fn jsonStringify(self: LoggingMessageParams, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("level");
        try self.level.jsonStringify(jws);
        if (self.logger) |l| {
            try jws.objectField("logger");
            try jws.write(l);
        }
        try jws.objectField("data");
        try jws.write(self.data);
        try jws.endObject();
    }
};

pub const ProgressParams = struct {
    progressToken: union(enum) {
        string: []const u8,
        number: i64,
    },
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,

    pub fn jsonStringify(self: ProgressParams, jws: *json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("progressToken");
        switch (self.progressToken) {
            .string => |s| try jws.write(s),
            .number => |n| try jws.write(n),
        }
        try jws.objectField("progress");
        try jws.write(self.progress);
        if (self.total) |t| {
            try jws.objectField("total");
            try jws.write(t);
        }
        if (self.message) |m| {
            try jws.objectField("message");
            try jws.write(m);
        }
        try jws.endObject();
    }
};

test "ServerCapabilities stringify" {
    const caps = ServerCapabilities{
        .tools = .{ .list_changed = true },
        .resources = .{ .subscribe = true },
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var jws: json.Stringify = .{ .writer = &aw.writer };
    try caps.jsonStringify(&jws);

    try aw.writer.flush();
    try std.testing.expect(aw.written().len > 0);
}
