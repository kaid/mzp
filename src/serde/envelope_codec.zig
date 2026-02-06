const std = @import("std");
const json = std.json;
const jsonrpc = @import("../jsonrpc.zig");

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
    try id.jsonStringify(&jws);
    try jws.objectField("method");
    try jws.write(method);
    if (@TypeOf(params) != @TypeOf(null)) {
        try jws.objectField("params");
        try writeRequestParams(&jws, params);
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
        try writeRequestParams(&jws, params);
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
    try id.jsonStringify(&jws);
    try jws.objectField("result");
    try writeRequestValue(&jws, result);
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
    try err.jsonStringify(&jws);

    try aw.writer.flush();
    const out = try allocator.dupe(u8, aw.written());
    aw.deinit();
    return out;
}

fn writeRequestParams(jws: *json.Stringify, params: anytype) !void {
    const T = @TypeOf(params);
    if (T == json.Value) {
        try jws.write(params);
    } else if (@typeInfo(T) == .optional) {
        if (params) |p| {
            try writeRequestParams(jws, p);
        } else {
            try jws.write(null);
        }
    } else if (@typeInfo(T) == .@"struct") {
        // If type has custom jsonStringify, use it
        if (@hasDecl(T, "jsonStringify")) {
            try params.jsonStringify(jws);
        } else {
            // Otherwise iterate fields with omit_null behavior
            try jws.beginObject();
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const field_value = @field(params, field.name);
                const FieldType = @TypeOf(field_value);
                if (@typeInfo(FieldType) == .optional) {
                    if (field_value != null) {
                        try jws.objectField(field.name);
                        try writeRequestValue(jws, field_value.?);
                    }
                } else {
                    try jws.objectField(field.name);
                    try writeRequestValue(jws, field_value);
                }
            }
            try jws.endObject();
        }
    } else {
        try jws.write(params);
    }
}

fn writeRequestValue(jws: *json.Stringify, value: anytype) !void {
    const T = @TypeOf(value);
    const is_container = switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
    if (is_container and @hasDecl(T, "jsonStringify")) {
        try value.jsonStringify(jws);
    } else {
        try jws.write(value);
    }
}
