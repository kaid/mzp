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
    err: jsonrpc.Error,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var jws: json.Stringify = .{ .writer = &aw.writer };
    try jws.beginObject();
    try jws.objectField("jsonrpc");
    try jws.write("2.0");
    try jws.objectField("error");
    try writeRequestValue(allocator, &jws, err);
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
