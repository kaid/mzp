const std = @import("std");
const izo = @import("izomorph");

pub const JsonSchema = struct {
    type: []const u8,
    properties: ?[]const Property = null,
    required: ?[]const []const u8 = null,
    items: ?*const JsonSchema = null,
    @"enum": ?[]const []const u8 = null,

    pub const Property = struct {
        name: []const u8,
        schema: JsonSchema,
    };

    pub fn jsonStringify(self: JsonSchema, jws: *std.json.Stringify) !void {
        try writeJsonSchema(jws, self);
    }
};

/// Generate JSON Schema struct from a Zig type at comptime
pub fn generate(comptime T: type) JsonSchema {
    return comptime generateSchema(T);
}

fn generateSchema(comptime T: type) JsonSchema {
    const info = @typeInfo(T);

    return switch (info) {
        .@"struct" => generateObjectSchema(T),
        .optional => |opt| generateSchema(opt.child),
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                JsonSchema{ .type = "string" }
            else
                JsonSchema{
                    .type = "array",
                    .items = &generateSchema(ptr.child),
                },
            else => @compileError("Unsupported pointer type for schema generation"),
        },
        .array => |arr| JsonSchema{
            .type = "array",
            .items = &generateSchema(arr.child),
        },
        .int => JsonSchema{ .type = "integer" },
        .float => JsonSchema{ .type = "number" },
        .bool => JsonSchema{ .type = "boolean" },
        .@"enum" => generateEnumSchema(T),
        else => @compileError("Unsupported type for schema generation: " ++ @typeName(T)),
    };
}

fn generateObjectSchema(comptime T: type) JsonSchema {
    const fields = @typeInfo(T).@"struct".fields;

    if (fields.len == 0) {
        return JsonSchema{ .type = "object", .properties = &[_]JsonSchema.Property{} };
    }

    comptime var props: []const JsonSchema.Property = &[_]JsonSchema.Property{};
    comptime var required: []const []const u8 = &[_][]const u8{};

    inline for (fields) |field| {
        const field_schema = generateSchema(field.type);
        props = props ++ [_]JsonSchema.Property{.{ .name = field.name, .schema = field_schema }};

        // Required array (non-optional fields without defaults)
        const is_optional = @typeInfo(field.type) == .optional;
        const has_default = field.default_value_ptr != null;

        if (!is_optional and !has_default) {
            required = required ++ [_][]const u8{field.name};
        }
    }

    return JsonSchema{
        .type = "object",
        .properties = props,
        .required = if (required.len > 0) required else null,
    };
}

fn generateEnumSchema(comptime T: type) JsonSchema {
    const info = @typeInfo(T).@"enum";

    comptime var values: []const []const u8 = &[_][]const u8{};

    inline for (info.fields) |field| {
        values = values ++ [_][]const u8{field.name};
    }

    return JsonSchema{
        .type = "string",
        .@"enum" = values,
    };
}

// ==================== Tests ====================

fn writeJsonSchema(jws: *std.json.Stringify, schema: JsonSchema) !void {
    try jws.beginObject();
    try jws.objectField("type");
    try jws.write(schema.type);

    if (schema.properties) |props| {
        try jws.objectField("properties");
        try jws.beginObject();
        for (props) |prop| {
            try jws.objectField(prop.name);
            try writeJsonSchema(jws, prop.schema);
        }
        try jws.endObject();
    }

    if (schema.required) |req| {
        try jws.objectField("required");
        try jws.write(req);
    }

    if (schema.items) |items| {
        try jws.objectField("items");
        try writeJsonSchema(jws, items.*);
    }

    if (schema.@"enum") |enum_vals| {
        try jws.objectField("enum");
        try jws.write(enum_vals);
    }

    try jws.endObject();
}

fn expectSchema(comptime T: type, expected: []const u8) !void {
    const js = generate(T);
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var jws: std.json.Stringify = .{ .writer = &aw.writer };

    try writeJsonSchema(&jws, js);
    try aw.writer.flush();
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "generate schema for simple struct" {
    const Args = struct {
        message: []const u8,
    };
    try expectSchema(Args, "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}");
}

test "generate schema for struct with optional" {
    const Args = struct {
        name: []const u8,
        nickname: ?[]const u8,
    };
    try expectSchema(Args, "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"nickname\":{\"type\":\"string\"}},\"required\":[\"name\"]}");
}

test "generate schema for struct with default" {
    const Args = struct {
        name: []const u8,
        count: u32 = 10,
    };
    try expectSchema(Args, "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\"}},\"required\":[\"name\"]}");
}

test "generate schema for nested struct" {
    const Inner = struct {
        value: i32,
    };
    const Outer = struct {
        inner: Inner,
    };
    try expectSchema(Outer, "{\"type\":\"object\",\"properties\":{\"inner\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"integer\"}},\"required\":[\"value\"]}},\"required\":[\"inner\"]}");
}

test "generate schema for enum" {
    const Color = enum { red, green, blue };
    const Args = struct {
        color: Color,
    };
    try expectSchema(Args, "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\",\"enum\":[\"red\",\"green\",\"blue\"]}},\"required\":[\"color\"]}");
}

test "generate schema for array" {
    const Args = struct {
        tags: []const []const u8,
    };
    try expectSchema(Args, "{\"type\":\"object\",\"properties\":{\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"tags\"]}");
}

test "generate schema for empty struct" {
    const Empty = struct {};
    try expectSchema(Empty, "{\"type\":\"object\",\"properties\":{}}");
}
