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
    comptime Mapper: type,
    input: []const u8,
) !Mapper.TargetType {
    // Use izomorph decode which respects Mapper configuration (aliases, etc.)
    return try izo.json.decode(allocator, Mapper, input);
}

pub fn decodeTypedDefault(
    allocator: std.mem.Allocator,
    comptime T: type,
    input: []const u8,
) !T {
    return try decodeTyped(allocator, defaultMapper(T), input);
}

pub fn valueToTyped(
    allocator: std.mem.Allocator,
    comptime Mapper: type,
    value: json.Value,
) !Mapper.TargetType {
    const json_text = try types.stringifyJsonAlloc(allocator, value);
    defer allocator.free(json_text);
    return try decodeTyped(allocator, Mapper, json_text);
}

pub fn valueToTypedDefault(
    allocator: std.mem.Allocator,
    comptime T: type,
    value: json.Value,
) !T {
    return try valueToTyped(allocator, defaultMapper(T), value);
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
