const std = @import("std");
const json = std.json;
const jsonrpc = @import("../jsonrpc.zig");
const izo = @import("izomorph");

const Io = std.Io;

pub fn encodeRequestAlloc(
    allocator: std.mem.Allocator,
    id: jsonrpc.RequestId,
    method: []const u8,
    params: anytype,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var jws: json.Stringify = .{ .writer = &aw.writer };
    try jws.beginObject();
    try jws.objectField("jsonrpc");
    try jws.write("2.0");
    try jws.objectField("id");
    try writeRequestValue(allocator, &jws, id);
    try jws.objectField("method");
    try jws.write(method);
    if (@TypeOf(params) != @TypeOf(null)) {
        try jws.objectField("params");
        try writeRequestParams(allocator, &jws, params);
    }
    try jws.endObject();

    try aw.writer.flush();
    const out = try allocator.dupe(u8, aw.written());
    aw.deinit();
    return out;
}

pub fn encodeNotificationAlloc(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var jws: json.Stringify = .{ .writer = &aw.writer };
    try jws.beginObject();
    try jws.objectField("jsonrpc");
    try jws.write("2.0");
    try jws.objectField("method");
    try jws.write(method);
    if (@TypeOf(params) != @TypeOf(null)) {
        try jws.objectField("params");
        try writeRequestParams(allocator, &jws, params);
    }
    try jws.endObject();

    try aw.writer.flush();
    const out = try allocator.dupe(u8, aw.written());
    aw.deinit();
    return out;
}

pub fn encodeResponseAlloc(
    allocator: std.mem.Allocator,
    id: jsonrpc.RequestId,
    result: anytype,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var jws: json.Stringify = .{ .writer = &aw.writer };
    try jws.beginObject();
    try jws.objectField("jsonrpc");
    try jws.write("2.0");
    try jws.objectField("id");
    try writeRequestValue(allocator, &jws, id);
    try jws.objectField("result");
    try writeRequestValue(allocator, &jws, result);
    try jws.endObject();

    try aw.writer.flush();
    const out = try allocator.dupe(u8, aw.written());
    aw.deinit();
    return out;
}

pub fn encodeErrorAlloc(
    allocator: std.mem.Allocator,
    id: ?jsonrpc.RequestId,
    err_data: jsonrpc.ErrorData,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var jws: json.Stringify = .{ .writer = &aw.writer };
    try jws.beginObject();
    try jws.objectField("jsonrpc");
    try jws.write("2.0");
    try jws.objectField("id");
    if (id) |req_id| {
        try writeRequestValue(allocator, &jws, req_id);
    } else {
        try jws.write(null);
    }
    try jws.objectField("error");
    try writeRequestValue(allocator, &jws, err_data);
    try jws.endObject();

    try aw.writer.flush();
    const out = try allocator.dupe(u8, aw.written());
    aw.deinit();
    return out;
}

fn writeRequestParams(allocator: std.mem.Allocator, jws: *json.Stringify, params: anytype) !void {
    const T = @TypeOf(params);
    if (T == json.Value) {
        try jws.write(params);
    } else if (@typeInfo(T) == .optional) {
        if (params) |p| {
            try writeRequestParams(allocator, jws, p);
        } else {
            try jws.write(null);
        }
    } else if (@typeInfo(T) == .@"struct") {
        // Use izo.json.encode for struct types
        const Mapper = if (@hasDecl(T, "Mapper")) T.Mapper else izo.Mapper(T, .{});
        const json_str = try izo.json.encode(allocator, params, Mapper, .{});
        defer allocator.free(json_str);
        var parsed = try std.json.parseFromSlice(json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try jws.write(parsed.value);
    } else {
        try jws.write(params);
    }
}

fn writeRequestValue(allocator: std.mem.Allocator, jws: *json.Stringify, value: anytype) !void {
    const T = @TypeOf(value);
    // For struct/enum/union types, use izo.json.encode
    const is_container = switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => true,
        else => false,
    };
    if (is_container) {
        // Use Mapper if available, otherwise create a default one
        const Mapper = if (@hasDecl(T, "Mapper")) T.Mapper else izo.Mapper(T, .{});
        const json_str = try izo.json.encode(allocator, value, Mapper, .{});
        defer allocator.free(json_str);
        var parsed = try std.json.parseFromSlice(json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        try jws.write(parsed.value);
    } else {
        try jws.write(value);
    }
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

    // 验证 JSON-RPC 格式
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"id\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"error\"") != null);

    // 验证 error 对象字段
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"message\":\"Method not found: unknown_method\"") != null);

    // 确保没有双重嵌套
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

    // 创建带 data 的 error
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
