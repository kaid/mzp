const std = @import("std");
const json = std.json;
const zjema_json = @import("zjema").json;
const types = @import("../types.zig");

pub fn defaultMapper(comptime T: type) type {
    return zjema_json.Mapper(T, .{});
}

pub fn encodeTyped(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime Mapper: type,
) ![]u8 {
    return @constCast(try zjema_json.encode(allocator, value, Mapper, .{}));
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
    // Use mapper-aware decode which respects Mapper configuration (aliases, etc.)
    return try zjema_json.decode(allocator, Mapper, input, .{});
}

pub fn decodeTypedDefault(
    allocator: std.mem.Allocator,
    comptime T: type,
    input: []const u8,
) !T {
    return try decodeTyped(allocator, defaultMapper(T), input);
}

/// Decodes a json.Value into a typed structure using a Mapper.
/// REQUIRES: `arena` must be an Arena allocator. The returned structure may contain
/// slices pointing into memory allocated by this function. All allocated memory will
/// be freed when the arena is deinitialized.
pub fn valueToTyped(
    arena: std.mem.Allocator,
    comptime Mapper: type,
    value: json.Value,
) !Mapper.TargetType {
    const json_text = try types.stringifyJsonAlloc(arena, value);
    // Note: We do NOT free json_text here because the resulting Mapper.TargetType
    // may contain slices that point into it. The arena will free all memory at once.
    return try decodeTyped(arena, Mapper, json_text);
}

pub fn valueToTypedDefault(
    arena: std.mem.Allocator,
    comptime T: type,
    value: json.Value,
) !T {
    return try valueToTyped(arena, defaultMapper(T), value);
}

/// Converts a typed structure into a json.Value using a Mapper.
/// REQUIRES: `arena` must be an Arena allocator. The returned json.Value may contain
/// slices pointing into memory allocated by this function. All allocated memory will
/// be freed when the arena is deinitialized.
pub fn typedToValue(
    arena: std.mem.Allocator,
    value: anytype,
    comptime Mapper: type,
) !json.Value {
    const json_text = try encodeTyped(arena, value, Mapper);
    // Note: We do NOT free json_text here because the resulting json.Value
    // may contain slices that point into it. The arena will free all memory at once.
    return try json.parseFromSliceLeaky(json.Value, arena, json_text, .{});
}

pub fn typedToValueDefault(
    arena: std.mem.Allocator,
    value: anytype,
) !json.Value {
    const T = @TypeOf(value);
    return try typedToValue(arena, value, defaultMapper(T));
}
