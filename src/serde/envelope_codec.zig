const std = @import("std");
const json = std.json;
const jsonrpc = @import("../jsonrpc.zig");
const izo = @import("izomorph");

const Io = std.Io;

/// Determines if a type is a container (struct, enum, union) that should be encoded with izo.
fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => true,
        else => false,
    };
}

/// Writes a JSON string value (with quotes and escaping) to the writer.
fn writeJsonString(writer: *std.Io.Writer, str: []const u8) !void {
    try writer.writeByte('"');
    // Escape special characters
    var start: usize = 0;
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        const escape: ?u8 = switch (str[i]) {
            '\\' => '\\',
            '"' => '"',
            '\n' => 'n',
            '\r' => 'r',
            '\t' => 't',
            0x08 => 'b',
            0x0C => 'f',
            else => null,
        };
        if (escape) |esc| {
            if (i > start) {
                try writer.writeAll(str[start..i]);
            }
            try writer.writeByte('\\');
            try writer.writeByte(esc);
            start = i + 1;
        }
    }
    if (i > start) {
        try writer.writeAll(str[start..i]);
    }
    try writer.writeByte('"');
}

/// Writes a simple value (number, bool, null) to the writer.
fn writeSimpleValue(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == @TypeOf(null)) {
        try writer.writeAll("null");
    } else if (T == bool) {
        try writer.writeAll(if (value) "true" else "false");
    } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try writer.writeAll(str);
    } else if (@typeInfo(T) == .float or @typeInfo(T) == .comptime_float) {
        var buf: [64]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try writer.writeAll(str);
    } else if (T == []const u8 or T == []u8) {
        try writeJsonString(writer, value);
    } else {
        // Fallback for other types
        var buf: [256]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{any}", .{value});
        try writer.writeAll(str);
    }
}

/// Writes a value using izo for containers, direct write for simple types.
fn writeValue(
    writer: *std.Io.Writer,
    value: anytype,
) !void {
    const T = @TypeOf(value);
    if (T == json.Value) {
        // For json.Value, we need to stringify it manually
        switch (value) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writeSimpleValue(writer, i),
            .float => |f| try writeSimpleValue(writer, f),
            .string => |s| try writeJsonString(writer, s),
            .array => |arr| {
                try writer.writeByte('[');
                for (arr.items, 0..) |item, idx| {
                    if (idx > 0) try writer.writeByte(',');
                    try writeValue(writer, item);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                var it = obj.iterator();
                var idx: usize = 0;
                while (it.next()) |entry| : (idx += 1) {
                    if (idx > 0) try writer.writeByte(',');
                    try writeJsonString(writer, entry.key_ptr.*);
                    try writer.writeByte(':');
                    try writeValue(writer, entry.value_ptr.*);
                }
                try writer.writeByte('}');
            },
        }
    } else if (isContainer(T)) {
        const Mapper = if (@hasDecl(T, "Mapper")) T.Mapper else izo.Mapper(T, .{});
        try izo.json.encodeToWriter(writer, value, Mapper, .{});
    } else {
        try writeSimpleValue(writer, value);
    }
}

/// Helper to encode to string using Writer
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

/// Streaming version: writes JSON-RPC request directly to the writer using only izo/manual JSON.
pub fn encodeRequestToWriter(
    writer: *std.Io.Writer,
    id: jsonrpc.RequestId,
    method: []const u8,
    params: anytype,
) !void {
    try writer.writeByte('{');

    try writeJsonString(writer, "jsonrpc");
    try writer.writeByte(':');
    try writeJsonString(writer, "2.0");

    try writer.writeByte(',');
    try writeJsonString(writer, "id");
    try writer.writeByte(':');
    try writeValue(writer, id);

    try writer.writeByte(',');
    try writeJsonString(writer, "method");
    try writer.writeByte(':');
    try writeJsonString(writer, method);

    if (@TypeOf(params) != @TypeOf(null)) {
        try writer.writeByte(',');
        try writeJsonString(writer, "params");
        try writer.writeByte(':');
        try writeValue(writer, params);
    }

    try writer.writeByte('}');
    try writer.flush();
}

/// Streaming version: writes JSON-RPC notification directly to the writer using only izo/manual JSON.
pub fn encodeNotificationToWriter(
    writer: *std.Io.Writer,
    method: []const u8,
    params: anytype,
) !void {
    try writer.writeByte('{');

    try writeJsonString(writer, "jsonrpc");
    try writer.writeByte(':');
    try writeJsonString(writer, "2.0");

    try writer.writeByte(',');
    try writeJsonString(writer, "method");
    try writer.writeByte(':');
    try writeJsonString(writer, method);

    if (@TypeOf(params) != @TypeOf(null)) {
        try writer.writeByte(',');
        try writeJsonString(writer, "params");
        try writer.writeByte(':');
        try writeValue(writer, params);
    }

    try writer.writeByte('}');
    try writer.flush();
}

/// Streaming version: writes JSON-RPC response directly to the writer using only izo/manual JSON.
pub fn encodeResponseToWriter(
    writer: *std.Io.Writer,
    id: jsonrpc.RequestId,
    result: anytype,
) !void {
    try writer.writeByte('{');

    try writeJsonString(writer, "jsonrpc");
    try writer.writeByte(':');
    try writeJsonString(writer, "2.0");

    try writer.writeByte(',');
    try writeJsonString(writer, "id");
    try writer.writeByte(':');
    try writeValue(writer, id);

    try writer.writeByte(',');
    try writeJsonString(writer, "result");
    try writer.writeByte(':');
    try writeValue(writer, result);

    try writer.writeByte('}');
    try writer.flush();
}

/// Streaming version: writes JSON-RPC error response directly to the writer using only izo/manual JSON.
pub fn encodeErrorToWriter(
    writer: *std.Io.Writer,
    id: ?jsonrpc.RequestId,
    err_data: jsonrpc.ErrorData,
) !void {
    try writer.writeByte('{');

    try writeJsonString(writer, "jsonrpc");
    try writer.writeByte(':');
    try writeJsonString(writer, "2.0");

    try writer.writeByte(',');
    try writeJsonString(writer, "id");
    try writer.writeByte(':');
    if (id) |req_id| {
        try writeValue(writer, req_id);
    } else {
        try writer.writeAll("null");
    }

    try writer.writeByte(',');
    try writeJsonString(writer, "error");
    try writer.writeByte(':');
    try writeValue(writer, err_data);

    try writer.writeByte('}');
    try writer.flush();
}

// Internal Alloc versions for testing - not exposed publicly

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

    // Verify JSON-RPC format
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"error\"") != null);

    // Verify error object fields
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"message\":\"Method not found: unknown_method\"") != null);

    // Ensure no double nesting
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

    // Create error with data
    var data_obj = std.json.ObjectMap.init(allocator);
    defer data_obj.deinit();
    try data_obj.put("field", std.json.Value{ .string = "value" });

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
