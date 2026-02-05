const std = @import("std");
const mzp = @import("mzp");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdio = mzp.StdioTransport.init(allocator);
    defer stdio.deinit();

    var threaded = std.Io.Threaded.init(allocator, .{
        .stack_size = 1024 * 1024,
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var server = mzp.Server.init(
        allocator,
        .{
            .name = "example-server",
            .version = "1.0.0",
            .description = "An example MCP server",
        },
        stdio.asTransport(),
    );
    defer server.deinit();

    const schema = .{
        .type = "object",
        .properties = .{
            .message = .{ .type = "string" },
        },
        .required = &[_][]const u8{"message"},
    };

    try server.capabilities.tools.add(
        .{
            .name = "echo",
            .description = "Echoes back the input",
            .inputSchema = schema,
        },
        echoHandler,
    );

    try server.run(io);
}

fn echoHandler(
    _: ?*anyopaque,
    _: []const u8,
    arguments: ?std.json.Value,
    _: mzp.server.ToolCallMeta,
    _: mzp.server.CancellationToken,
    allocator: std.mem.Allocator,
) !mzp.types.OwnedCallToolResult {
    const text = if (arguments) |args| blk: {
        const obj = switch (args) {
            .object => |o| o,
            else => break :blk "No arguments",
        };
        const msg = obj.get("message") orelse break :blk "No message";
        break :blk switch (msg) {
            .string => |s| s,
            else => "Invalid message type",
        };
    } else "No arguments";

    var result = mzp.types.OwnedCallToolResult.init(allocator);
    try result.addText(text);
    return result;
}
