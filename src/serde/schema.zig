/// JSON Schema generation from Zig types
///
/// Generates JSON Schema from Zig struct types at comptime.
/// Used for auto-generating tool input schemas from handler argument types.
const std = @import("std");

/// Generate JSON Schema string from a Zig type at comptime
pub fn generate(comptime T: type) []const u8 {
    return comptime generateSchema(T);
}

fn generateSchema(comptime T: type) []const u8 {
    const info = @typeInfo(T);

    return switch (info) {
        .@"struct" => generateObjectSchema(T),
        .optional => |opt| generateSchema(opt.child),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                "{\"type\":\"string\"}"
            else
                "{\"type\":\"array\",\"items\":" ++ generateSchema(ptr.child) ++ "}",
            else => @compileError("Unsupported pointer type for schema generation"),
        },
        .array => |arr| "{\"type\":\"array\",\"items\":" ++ generateSchema(arr.child) ++ "}",
        .int => "{\"type\":\"integer\"}",
        .float => "{\"type\":\"number\"}",
        .bool => "{\"type\":\"boolean\"}",
        .@"enum" => generateEnumSchema(T),
        else => @compileError("Unsupported type for schema generation: " ++ @typeName(T)),
    };
}

fn generateObjectSchema(comptime T: type) []const u8 {
    const fields = @typeInfo(T).@"struct".fields;

    if (fields.len == 0) {
        return "{\"type\":\"object\",\"properties\":{}}";
    }

    comptime var props: []const u8 = "";
    comptime var required: []const u8 = "";
    comptime var first_prop = true;
    comptime var first_req = true;

    inline for (fields) |field| {
        // Field property
        if (!first_prop) {
            props = props ++ ",";
        }
        first_prop = false;

        const field_schema = generateSchema(field.type);
        props = props ++ "\"" ++ field.name ++ "\":" ++ field_schema;

        // Required array (non-optional fields without defaults)
        const is_optional = @typeInfo(field.type) == .optional;
        const has_default = field.default_value_ptr != null;

        if (!is_optional and !has_default) {
            if (!first_req) {
                required = required ++ ",";
            }
            first_req = false;
            required = required ++ "\"" ++ field.name ++ "\"";
        }
    }

    if (required.len > 0) {
        return "{\"type\":\"object\",\"properties\":{" ++ props ++ "},\"required\":[" ++ required ++ "]}";
    } else {
        return "{\"type\":\"object\",\"properties\":{" ++ props ++ "}}";
    }
}

fn generateEnumSchema(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"enum";

    comptime var values: []const u8 = "";
    comptime var first = true;

    inline for (info.fields) |field| {
        if (!first) {
            values = values ++ ",";
        }
        first = false;
        values = values ++ "\"" ++ field.name ++ "\"";
    }

    return "{\"type\":\"string\",\"enum\":[" ++ values ++ "]}";
}

// ==================== Tests ====================

test "generate schema for simple struct" {
    const Args = struct {
        message: []const u8,
    };

    const schema = generate(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}",
        schema,
    );
}

test "generate schema for struct with optional" {
    const Args = struct {
        name: []const u8,
        nickname: ?[]const u8,
    };

    const schema = generate(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"nickname\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
        schema,
    );
}

test "generate schema for struct with default" {
    const Args = struct {
        name: []const u8,
        count: u32 = 10,
    };

    const schema = generate(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\"}},\"required\":[\"name\"]}",
        schema,
    );
}

test "generate schema for nested struct" {
    const Inner = struct {
        value: i32,
    };
    const Outer = struct {
        inner: Inner,
    };

    const schema = generate(Outer);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"inner\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}},\"required\":[\"value\"]}},\"required\":[\"inner\"]}",
        schema,
    );
}

test "generate schema for enum" {
    const Color = enum { red, green, blue };
    const Args = struct {
        color: Color,
    };

    const schema = generate(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\",\"enum\":[\"red\",\"green\",\"blue\"]}},\"required\":[\"color\"]}",
        schema,
    );
}

test "generate schema for array" {
    const Args = struct {
        tags: []const []const u8,
    };

    const schema = generate(Args);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"tags\"]}",
        schema,
    );
}

test "generate schema for empty struct" {
    const Empty = struct {};

    const schema = generate(Empty);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{}}",
        schema,
    );
}
