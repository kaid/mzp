const std = @import("std");
const mzp = @import("mzp");
const izo = @import("izomorph");

const EchoArgs = struct {
    message: []const u8,
};
const EchoArgsMapper = izo.Mapper(EchoArgs, .{});

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

    // addTyped auto-generates inputSchema from EchoArgs at comptime
    try server.capabilities.tools.addTyped(
        .{
            .name = "echo",
            .description = "Echoes back the input",
        },
        EchoArgsMapper,
        echoHandler,
        null,
    );

    try server.run(io);
}

fn echoHandler(
    _: ?*anyopaque,
    _: []const u8,
    arguments: ?EchoArgs,
    _: mzp.server.ToolCallMeta,
    _: mzp.server.CancellationToken,
    allocator: std.mem.Allocator,
) !mzp.types.OwnedCallToolResult {
    const text = if (arguments) |args| args.message else "No arguments";

    var result = mzp.types.OwnedCallToolResult.init(allocator);
    try result.addText(text);
    return result;
}
