const std = @import("std");
const json = std.json;
const jsonrpc = @import("../jsonrpc.zig");
const zjema_json = @import("zjema").json;

const Io = std.Io;

/// Writes a JSON-RPC request to the writer using type-safe serialization.
/// This is a convenience wrapper around jsonrpc.TypedRequest.
/// For null params, falls back to RawRequest with optional json.Value.
pub fn encodeRequestToWriter(
    writer: *std.Io.Writer,
    id: jsonrpc.RequestId,
    method: []const u8,
    params: anytype,
) !void {
    const Params = @TypeOf(params);

    // Check if params is null at compile time where possible
    const is_null = @typeInfo(Params) == .null;

    if (is_null) {
        // Use RawRequest for null params (no params field)
        const req = jsonrpc.RawRequest{
            .id = id,
            .method = method,
            .params = null,
        };
        try zjema_json.encodeToWriter(writer, req, jsonrpc.RawRequest.Mapper, .{});
    } else {
        const req = jsonrpc.TypedRequest(Params){
            .id = id,
            .method = method,
            .params = params,
        };
        try zjema_json.encodeToWriter(writer, req, jsonrpc.TypedRequest(Params).Mapper, .{});
    }
    try writer.flush();
}

/// Writes a JSON-RPC notification to the writer using type-safe serialization.
/// This is a convenience wrapper around jsonrpc.TypedNotification.
/// For null params, falls back to RawNotification with optional json.Value.
pub fn encodeNotificationToWriter(
    writer: *std.Io.Writer,
    method: []const u8,
    params: anytype,
) !void {
    const Params = @TypeOf(params);

    // Check if params is null at compile time where possible
    const is_null = @typeInfo(Params) == .null;

    if (is_null) {
        // Use RawNotification for null params (no params field)
        const notif = jsonrpc.RawNotification{
            .method = method,
            .params = null,
        };
        try zjema_json.encodeToWriter(writer, notif, jsonrpc.RawNotification.Mapper, .{});
    } else {
        const notif = jsonrpc.TypedNotification(Params){
            .method = method,
            .params = params,
        };
        try zjema_json.encodeToWriter(writer, notif, jsonrpc.TypedNotification(Params).Mapper, .{});
    }
    try writer.flush();
}

/// Writes a JSON-RPC response to the writer using type-safe serialization.
/// This is a convenience wrapper around jsonrpc.TypedResponse.
pub fn encodeResponseToWriter(
    writer: *std.Io.Writer,
    id: jsonrpc.RequestId,
    result: anytype,
) !void {
    const Result = @TypeOf(result);
    const resp = jsonrpc.TypedResponse(Result){
        .id = id,
        .result = result,
    };

    try zjema_json.encodeToWriter(writer, resp, jsonrpc.TypedResponse(Result).Mapper, .{});
    try writer.flush();
}

/// Writes a JSON-RPC error response to the writer.
pub fn encodeErrorToWriter(
    writer: *std.Io.Writer,
    id: ?jsonrpc.RequestId,
    err_data: jsonrpc.ErrorData,
) !void {
    const err = jsonrpc.Error{
        .id = id,
        .@"error" = err_data,
    };

    try zjema_json.encodeToWriter(writer, err, jsonrpc.Error.Mapper, .{});
    try writer.flush();
}

// Internal test helpers

fn encodeToString(allocator: std.mem.Allocator, writer_fn: anytype, args: anytype) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const result = @call(.auto, writer_fn, .{&aw.writer} ++ args);
    if (result) {
        try aw.writer.flush();
        const out = try allocator.dupe(u8, aw.written());
        aw.deinit();
        return out;
    } else |err| {
        aw.deinit();
        return err;
    }
}

fn encodeRequestAlloc(
    allocator: std.mem.Allocator,
    id: jsonrpc.RequestId,
    method: []const u8,
    params: anytype,
) ![]u8 {
    return encodeToString(allocator, encodeRequestToWriter, .{ id, method, params });
}

fn encodeNotificationAlloc(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
) ![]u8 {
    return encodeToString(allocator, encodeNotificationToWriter, .{ method, params });
}

fn encodeResponseAlloc(
    allocator: std.mem.Allocator,
    id: jsonrpc.RequestId,
    result: anytype,
) ![]u8 {
    return encodeToString(allocator, encodeResponseToWriter, .{ id, result });
}

fn encodeErrorAlloc(
    allocator: std.mem.Allocator,
    id: ?jsonrpc.RequestId,
    err_data: jsonrpc.ErrorData,
) ![]u8 {
    return encodeToString(allocator, encodeErrorToWriter, .{ id, err_data });
}

// Tests

test "encode request with number id" {
    const allocator = std.testing.allocator;
    const id = jsonrpc.RequestId{ .number = 42 };
    const params = struct { name: []const u8, value: i32 }{ .name = "test", .value = 123 };

    const encoded = try encodeRequestAlloc(allocator, id, "test/method", params);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"test/method\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"name\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"value\":123") != null);
}

test "encode request with string id" {
    const allocator = std.testing.allocator;
    const id = jsonrpc.RequestId{ .string = "req-123" };
    const params = struct { active: bool }{ .active = true };

    const encoded = try encodeRequestAlloc(allocator, id, "ping", params);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":\"req-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"active\":true") != null);
}

test "encode notification" {
    const allocator = std.testing.allocator;
    const params = struct { level: []const u8 }{ .level = "info" };

    const encoded = try encodeNotificationAlloc(allocator, "notifications/message", params);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"notifications/message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\"") == null);
}

test "encode response" {
    const allocator = std.testing.allocator;
    const id = jsonrpc.RequestId{ .number = 99 };
    const result = struct { success: bool, data: ?[]const u8 }{ .success = true, .data = "ok" };

    const encoded = try encodeResponseAlloc(allocator, id, result);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"data\":\"ok\"") != null);
}

test "encode error response with id" {
    const allocator = std.testing.allocator;
    const id = jsonrpc.RequestId{ .number = 100 };
    const err_data = jsonrpc.ErrorData{
        .code = .method_not_found,
        .message = "Method not found: unknown_method",
    };

    const encoded = try encodeErrorAlloc(allocator, id, err_data);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"message\":\"Method not found: unknown_method\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"error\":{\"error\"") == null);
}

test "encode error response without id (parse error)" {
    const allocator = std.testing.allocator;
    const err_data = jsonrpc.ErrorData{
        .code = .parse_error,
        .message = "Invalid JSON",
    };

    const encoded = try encodeErrorAlloc(allocator, null, err_data);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"code\":-32700") != null);
}

test "encode error with data field" {
    const allocator = std.testing.allocator;
    const id = jsonrpc.RequestId{ .string = "req-abc" };

    var data_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer data_obj.deinit(allocator);
    try data_obj.put(allocator, "field", std.json.Value{ .string = "value" });

    const err_data = jsonrpc.ErrorData{
        .code = .invalid_params,
        .message = "Invalid parameters",
        .data = std.json.Value{ .object = data_obj },
    };

    const encoded = try encodeErrorAlloc(allocator, id, err_data);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":\"req-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"code\":-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"field\":\"value\"") != null);
}
