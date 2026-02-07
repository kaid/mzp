const std = @import("std");
const json = std.json;
const izo = @import("izomorph");
const types = @import("../types.zig");

pub fn defaultMapper(comptime T: type) type {
    return izo.Mapper(T, .{});
}

pub fn encodeTyped(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime Mapper: type,
) ![]u8 {
    return @constCast(try izo.json.encode(allocator, value, Mapper, .{}));
}

pub fn encodeTypedDefault(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]u8 {
    const T = @TypeOf(value);
    return try encodeTyped(allocator, value, defaultMapper(T));
}

pub fn decodeTyped(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime Mapper: type,
    input: []const u8,
) !T {
    _ = Mapper;
    // Use std.json.parseFromSliceLeaky which returns T directly without Parsed wrapper
    // Strings will be allocated using the provided allocator and remain valid
    return try std.json.parseFromSliceLeaky(T, allocator, input, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    });
}

pub fn decodeTypedDefault(
    allocator: std.mem.Allocator,
    comptime T: type,
    input: []const u8,
) !T {
    return try decodeTyped(allocator, T, defaultMapper(T), input);
}

pub fn valueToTyped(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime Mapper: type,
    value: json.Value,
) !T {
    const json_text = try types.stringifyJsonAlloc(allocator, value);
    defer allocator.free(json_text);
    return try decodeTyped(allocator, T, Mapper, json_text);
}

pub fn valueToTypedDefault(
    allocator: std.mem.Allocator,
    comptime T: type,
    value: json.Value,
) !T {
    return try valueToTyped(allocator, T, defaultMapper(T), value);
}

pub fn typedToValue(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime Mapper: type,
) !json.Value {
    const json_text = try encodeTyped(allocator, value, Mapper);
    defer allocator.free(json_text);
    return try json.parseFromSliceLeaky(json.Value, allocator, json_text, .{});
}

pub fn typedToValueDefault(
    allocator: std.mem.Allocator,
    value: anytype,
) !json.Value {
    const T = @TypeOf(value);
    return try typedToValue(allocator, value, defaultMapper(T));
}
