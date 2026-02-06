const std = @import("std");

pub fn MethodSpec(
    comptime method_name: []const u8,
    comptime RequestType: type,
    comptime ResponseType: type,
    comptime RequestMapper: type,
    comptime ResponseMapper: type,
) type {
    return struct {
        pub const method = method_name;
        pub const Req = RequestType;
        pub const Resp = ResponseType;
        pub const ReqMapperType = RequestMapper;
        pub const RespMapperType = ResponseMapper;
    };
}

pub fn ToolSpec(
    comptime tool_name: []const u8,
    comptime ArgsType: type,
    comptime ResultType: type,
    comptime ArgsMapper: type,
) type {
    return struct {
        pub const name = tool_name;
        pub const Args = ArgsType;
        pub const Result = ResultType;
        pub const ArgsMapperType = ArgsMapper;
    };
}

pub fn assertUniqueMethods(comptime Specs: anytype) void {
    inline for (Specs, 0..) |S, i| {
        if (!@hasDecl(S, "method")) {
            @compileError("Method spec missing `method` declaration");
        }
        inline for (Specs[(i + 1)..]) |Other| {
            if (comptime std.mem.eql(u8, S.method, Other.method)) {
                @compileError("Duplicate method registration: " ++ S.method);
            }
        }
    }
}

pub fn assertUniqueTools(comptime Specs: anytype) void {
    inline for (Specs, 0..) |S, i| {
        if (!@hasDecl(S, "name")) {
            @compileError("Tool spec missing `name` declaration");
        }
        inline for (Specs[(i + 1)..]) |Other| {
            if (comptime std.mem.eql(u8, S.name, Other.name)) {
                @compileError("Duplicate tool registration: " ++ S.name);
            }
        }
    }
}
