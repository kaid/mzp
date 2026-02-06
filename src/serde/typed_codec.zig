const std = @import("std");
const json = std.json;
const izo = @import("izomorph");
const types = @import("../types.zig");
const meta_module = izo.meta;

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
    const Decoder = createOwnedDecoder(T, Mapper);
    var scanner = json.Scanner.initCompleteInput(allocator, input);
    defer scanner.deinit();

    const options = json.ParseOptions{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
        .max_value_len = input.len,
        .allocate = .alloc_always,
    };

    return try Decoder.jsonParse(allocator, &scanner, options);
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

fn createOwnedDecoder(comptime T: type, comptime MapperType: type) type {
    return struct {
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: json.ParseOptions,
        ) json.ParseError(@TypeOf(source.*))!T {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var result: T = undefined;
            var fields_seen = [_]bool{false} ** MapperType.fields.len;

            while (true) {
                var name_token: ?json.Token = try source.nextAllocMax(
                    allocator,
                    .alloc_always,
                    options.max_value_len orelse json.default_max_value_len,
                );

                const json_field_name = switch (name_token.?) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };

                var matched = false;
                inline for (MapperType.fields, 0..) |field_meta, i| {
                    if (field_meta.should_skip) continue;

                    if (std.mem.eql(u8, field_meta.serialized_name, json_field_name)) {
                        if (name_token) |token| {
                            switch (token) {
                                .allocated_string => |slice| allocator.free(slice),
                                else => {},
                            }
                        }
                        name_token = null;

                        if (fields_seen[i]) {
                            switch (options.duplicate_field_behavior) {
                                .use_first => {
                                    _ = try parseFieldValue(allocator, source, field_meta, options);
                                    matched = true;
                                    break;
                                },
                                .@"error" => return error.DuplicateField,
                                .use_last => {},
                            }
                        }

                        @field(result, field_meta.name) = try parseFieldValue(allocator, source, field_meta, options);
                        fields_seen[i] = true;
                        matched = true;
                        break;
                    }
                }

                if (!matched) {
                    if (name_token) |token| {
                        switch (token) {
                            .allocated_string => |slice| allocator.free(slice),
                            else => {},
                        }
                    }

                    if (options.ignore_unknown_fields) {
                        try source.skipValue();
                    } else {
                        return error.UnknownField;
                    }
                }
            }

            inline for (MapperType.fields, 0..) |field_meta, i| {
                if (!field_meta.should_skip and !fields_seen[i]) {
                    const field_type = @TypeOf(@field(result, field_meta.name));
                    if (comptime @typeInfo(field_type) == .optional) {
                        @field(result, field_meta.name) = null;
                    }
                }
            }

            return result;
        }

        fn parseFieldValue(
            allocator: std.mem.Allocator,
            source: anytype,
            comptime field_meta: meta_module.FieldMeta,
            options: json.ParseOptions,
        ) !@TypeOf(@field(@as(T, undefined), field_meta.name)) {
            const FieldType = @TypeOf(@field(@as(T, undefined), field_meta.name));

            var actual_options = options;
            actual_options.allocate = .alloc_always;
            if (actual_options.max_value_len == null) {
                actual_options.max_value_len = json.default_max_value_len;
            }

            if (comptime field_meta.has_nested_mapper) {
                const NestedDecoder = createOwnedDecoder(FieldType, field_meta.nested_mapper);
                return try NestedDecoder.jsonParse(allocator, source, actual_options);
            }

            return try json.innerParse(FieldType, allocator, source, actual_options);
        }
    };
}
