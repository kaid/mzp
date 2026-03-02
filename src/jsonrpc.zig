const std = @import("std");
const json = std.json;
const zjema_json = @import("zjema").json;

pub const JSONRPC_VERSION = "2.0";

// ============================================================================
// RequestId - unchanged
// ============================================================================
pub const RequestId = union(enum) {
    string: []const u8,
    number: i64,

    pub const Mapper = zjema_json.Mapper(RequestId, .{ .strategy = .bare });

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !RequestId {
        _ = options;
        const token = try source.next();
        switch (token) {
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .number => |n| {
                const num = try std.fmt.parseInt(i64, n, 10);
                return .{ .number = num };
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn eql(self: RequestId, other: RequestId) bool {
        return switch (self) {
            .string => |s| switch (other) {
                .string => |os| std.mem.eql(u8, s, os),
                .number => false,
            },
            .number => |n| switch (other) {
                .string => false,
                .number => |on| n == on,
            },
        };
    }
};

// ============================================================================
// ErrorCode - unchanged
// ============================================================================
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    connection_closed = -32000,
    request_timeout = -32001,

    pub const Mapper = zjema_json.Mapper(ErrorCode, .{ .strategy = .bare });
};

// ============================================================================
// ErrorData - unchanged
// ============================================================================
pub const ErrorData = struct {
    code: ErrorCode,
    message: []const u8,
    data: ?json.Value = null,

    pub const Mapper = zjema_json.Mapper(ErrorData, .{
        .data = .{ .omit_null = true },
    });
};

// ============================================================================
// Typed Message Types (Generic) - For serialization with type safety
// ============================================================================

/// Generic Request type for type-safe serialization
/// Params: the type of request parameters (use void for no params)
pub fn TypedRequest(comptime Params: type) type {
    return struct {
        jsonrpc: []const u8 = JSONRPC_VERSION,
        id: RequestId,
        method: []const u8,
        params: ?Params = null,

        pub const Mapper = zjema_json.Mapper(@This(), .{
            .params = .{ .omit_null = true },
        });
    };
}

/// Generic Notification type for type-safe serialization
/// Params: the type of notification parameters (use void for no params)
pub fn TypedNotification(comptime Params: type) type {
    return struct {
        jsonrpc: []const u8 = JSONRPC_VERSION,
        method: []const u8,
        params: ?Params = null,

        pub const Mapper = zjema_json.Mapper(@This(), .{
            .params = .{ .omit_null = true },
        });
    };
}

/// Generic Response type for type-safe serialization
/// Result: the type of response result
pub fn TypedResponse(comptime Result: type) type {
    return struct {
        jsonrpc: []const u8 = JSONRPC_VERSION,
        id: RequestId,
        result: Result,

        pub const Mapper = zjema_json.Mapper(@This(), .{});
    };
}

/// Generic Error type
/// Note: Error data structure is fixed per JSON-RPC spec
pub const Error = struct {
    jsonrpc: []const u8 = JSONRPC_VERSION,
    id: ?RequestId = null,
    @"error": ErrorData,

    pub const Mapper = zjema_json.Mapper(@This(), .{
        // Note: JSON-RPC spec requires id to be present even when null (for parse errors)
        // .id field should not be omitted
    });

    pub fn methodNotFound(id: RequestId, method: []const u8) Error {
        _ = method;
        return .{
            .id = id,
            .@"error" = .{
                .code = .method_not_found,
                .message = "Method not found",
            },
        };
    }

    pub fn invalidParams(id: RequestId, message: []const u8) Error {
        return .{
            .id = id,
            .@"error" = .{
                .code = .invalid_params,
                .message = message,
            },
        };
    }

    pub fn internalError(id: RequestId, message: []const u8) Error {
        return .{
            .id = id,
            .@"error" = .{
                .code = .internal_error,
                .message = message,
            },
        };
    }

    pub fn parseError(message: []const u8) Error {
        return .{
            .id = null,
            .@"error" = .{
                .code = .parse_error,
                .message = message,
            },
        };
    }

    pub fn invalidRequest(message: []const u8) Error {
        return .{
            .id = null,
            .@"error" = .{
                .code = .invalid_request,
                .message = message,
            },
        };
    }
};

// ============================================================================
// Raw Message Types - Aliases for parsing with json.Value (type erasure)
// ============================================================================

/// Non-generic Request for parsing (params stored as json.Value)
pub const RawRequest = TypedRequest(json.Value);

/// Non-generic Notification for parsing (params stored as json.Value)
pub const RawNotification = TypedNotification(json.Value);

/// Non-generic Response for parsing (result stored as json.Value)
pub const RawResponse = TypedResponse(json.Value);

/// Raw Message union for parsing incoming messages
pub const RawMessage = union(enum) {
    request: RawRequest,
    response: RawResponse,
    @"error": Error,
    notification: RawNotification,

    pub const Mapper = zjema_json.Mapper(RawMessage, .{ .strategy = .bare });

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !RawMessage {
        var parsed = try json.parseFromSlice(json.Value, allocator, input, .{});
        defer parsed.deinit();

        return parseFromValue(allocator, parsed.value);
    }

    pub fn parseFromValue(allocator: std.mem.Allocator, value: json.Value) !RawMessage {
        const obj = switch (value) {
            .object => |o| o,
            else => return error.InvalidRequest,
        };

        const jsonrpc_val = obj.get("jsonrpc") orelse return error.InvalidRequest;
        const jsonrpc_str = switch (jsonrpc_val) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };
        if (!std.mem.eql(u8, jsonrpc_str, JSONRPC_VERSION)) {
            return error.InvalidRequest;
        }

        const has_id = obj.get("id") != null;
        const has_method = obj.get("method") != null;
        const has_result = obj.get("result") != null;
        const has_error = obj.get("error") != null;

        if (has_method and has_id and !has_result and !has_error) {
            return .{ .request = try parseRequest(allocator, obj) };
        } else if (has_method and !has_id) {
            return .{ .notification = try parseNotification(allocator, obj) };
        } else if (has_id and has_result) {
            return .{ .response = try parseResponse(allocator, obj) };
        } else if (has_error) {
            return .{ .@"error" = try parseErrorResponse(allocator, obj) };
        }

        return error.InvalidRequest;
    }

    fn parseRequest(allocator: std.mem.Allocator, obj: json.ObjectMap) !RawRequest {
        const id = try parseRequestId(allocator, obj.get("id").?);
        const method_val = obj.get("method") orelse return error.InvalidRequest;
        const method = switch (method_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidRequest,
        };
        const params = if (obj.get("params")) |p| try cloneValue(allocator, p) else null;

        return .{
            .id = id,
            .method = method,
            .params = params,
        };
    }

    fn parseNotification(allocator: std.mem.Allocator, obj: json.ObjectMap) !RawNotification {
        const method_val = obj.get("method") orelse return error.InvalidRequest;
        const method = switch (method_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidRequest,
        };
        const params = if (obj.get("params")) |p| try cloneValue(allocator, p) else null;

        return .{
            .method = method,
            .params = params,
        };
    }

    fn parseResponse(allocator: std.mem.Allocator, obj: json.ObjectMap) !RawResponse {
        const id = try parseRequestId(allocator, obj.get("id").?);
        const result = try cloneValue(allocator, obj.get("result").?);

        return .{
            .id = id,
            .result = result,
        };
    }

    fn parseErrorResponse(allocator: std.mem.Allocator, obj: json.ObjectMap) !Error {
        const id_val = obj.get("id");
        const id: ?RequestId = if (id_val) |v| switch (v) {
            .null => null,
            else => try parseRequestId(allocator, v),
        } else null;

        const error_obj = switch (obj.get("error").?) {
            .object => |o| o,
            else => return error.InvalidRequest,
        };

        const code_val = error_obj.get("code") orelse return error.InvalidRequest;
        const code: ErrorCode = switch (code_val) {
            .integer => |i| @enumFromInt(@as(i32, @intCast(i))),
            else => return error.InvalidRequest,
        };

        const message_val = error_obj.get("message") orelse return error.InvalidRequest;
        const message = switch (message_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.InvalidRequest,
        };

        const data = if (error_obj.get("data")) |d| try cloneValue(allocator, d) else null;

        return .{
            .id = id,
            .@"error" = .{
                .code = code,
                .message = message,
                .data = data,
            },
        };
    }

    fn parseRequestId(allocator: std.mem.Allocator, value: json.Value) !RequestId {
        return switch (value) {
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .integer => |i| .{ .number = i },
            else => error.InvalidRequest,
        };
    }

    pub fn cloneValue(allocator: std.mem.Allocator, value: json.Value) !json.Value {
        return switch (value) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_arr = json.Array.init(allocator);
                for (arr.items) |item| {
                    try new_arr.append(try cloneValue(allocator, item));
                }
                return .{ .array = new_arr };
            },
            .object => |obj| {
                var new_obj = json.ObjectMap.init(allocator);
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try new_obj.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneValue(allocator, entry.value_ptr.*));
                }
                return .{ .object = new_obj };
            },
        };
    }

    pub fn freeValue(allocator: std.mem.Allocator, value: json.Value) void {
        switch (value) {
            .string => |s| allocator.free(s),
            .number_string => |s| allocator.free(s),
            .array => |arr| {
                for (arr.items) |item| {
                    freeValue(allocator, item);
                }
                var mut_arr = arr;
                mut_arr.deinit();
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeValue(allocator, entry.value_ptr.*);
                }
                var mut_obj = obj;
                mut_obj.deinit();
            },
            else => {},
        }
    }

    pub fn freeRequestId(allocator: std.mem.Allocator, id: RequestId) void {
        switch (id) {
            .string => |s| allocator.free(s),
            .number => {},
        }
    }

    pub fn freeRequest(allocator: std.mem.Allocator, req: RawRequest) void {
        freeRequestId(allocator, req.id);
        allocator.free(req.method);
        if (req.params) |p| {
            freeValue(allocator, p);
        }
    }

    pub fn freeNotification(allocator: std.mem.Allocator, notif: RawNotification) void {
        allocator.free(notif.method);
        if (notif.params) |p| {
            freeValue(allocator, p);
        }
    }

    pub fn freeResponse(allocator: std.mem.Allocator, resp: RawResponse) void {
        freeRequestId(allocator, resp.id);
        freeValue(allocator, resp.result);
    }

    pub fn freeErrorResponse(allocator: std.mem.Allocator, err: Error) void {
        if (err.id) |id| freeRequestId(allocator, id);
        allocator.free(err.@"error".message);
        if (err.@"error".data) |d| freeValue(allocator, d);
    }

    pub fn freeMessage(allocator: std.mem.Allocator, msg: RawMessage) void {
        switch (msg) {
            .request => |r| freeRequest(allocator, r),
            .notification => |n| freeNotification(allocator, n),
            .response => |r| freeResponse(allocator, r),
            .@"error" => |e| freeErrorResponse(allocator, e),
        }
    }

    pub fn stringify(self: RawMessage, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();

        try zjema_json.encodeToWriter(
            &aw.writer,
            self,
            RawMessage.Mapper,
            .{},
        );

        try aw.writer.flush();
        const result = try allocator.dupe(u8, aw.written());
        aw.deinit();
        return result;
    }
};

// ============================================================================
// Backward Compatibility Aliases
// ============================================================================

/// Use RawRequest for parsing, or TypedRequest(Params) for type-safe serialization
pub const Request = RawRequest;
/// Use RawNotification for parsing, or TypedNotification(Params) for type-safe serialization
pub const Notification = RawNotification;
/// Use RawResponse for parsing, or TypedResponse(Result) for type-safe serialization
pub const Response = RawResponse;
/// Use RawMessage for parsing with json.Value
pub const Message = RawMessage;

// ============================================================================
// Tests
// ============================================================================

test "parse request" {
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"test","params":{"foo":"bar"}}
    ;
    const msg = try RawMessage.parse(std.testing.allocator, input);
    defer RawMessage.freeMessage(std.testing.allocator, msg);

    try std.testing.expect(msg == .request);
    try std.testing.expectEqualStrings("test", msg.request.method);
    try std.testing.expect(msg.request.id.number == 1);
}

test "parse notification" {
    const input =
        \\{"jsonrpc":"2.0","method":"test"}
    ;
    const msg = try RawMessage.parse(std.testing.allocator, input);
    defer RawMessage.freeMessage(std.testing.allocator, msg);

    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("test", msg.notification.method);
}

test "parse request with string id" {
    const input =
        \\{"jsonrpc":"2.0","id":"abc","method":"test"}
    ;
    const msg = try RawMessage.parse(std.testing.allocator, input);
    defer RawMessage.freeMessage(std.testing.allocator, msg);

    try std.testing.expect(msg == .request);
    try std.testing.expect(msg.request.id == .string);
    try std.testing.expectEqualStrings("abc", msg.request.id.string);
}

test "typed request serialization" {
    const TestParams = struct {
        foo: []const u8,
        bar: i32,
    };

    const req = TypedRequest(TestParams){
        .id = .{ .number = 42 },
        .method = "test/method",
        .params = .{ .foo = "hello", .bar = 123 },
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try zjema_json.encodeToWriter(&aw.writer, req, TypedRequest(TestParams).Mapper, .{});
    try aw.writer.flush();

    const json_str = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"method\":\"test/method\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"foo\":\"hello\"") != null);
}
