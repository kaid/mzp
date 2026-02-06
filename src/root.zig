const std = @import("std");

pub const jsonrpc = @import("jsonrpc.zig");
pub const types = @import("types.zig");
pub const transport = @import("transport.zig");
pub const server = @import("server.zig");
pub const client = @import("client.zig");
pub const serde = struct {
    pub const typed_codec = @import("serde/typed_codec.zig");
    pub const envelope_codec = @import("serde/envelope_codec.zig");
};
pub const typed_registry = @import("typed_registry.zig");

pub const JsonRpcRequest = jsonrpc.Request;
pub const JsonRpcResponse = jsonrpc.Response;
pub const JsonRpcNotification = jsonrpc.Notification;
pub const JsonRpcError = jsonrpc.Error;
pub const JsonRpcMessage = jsonrpc.Message;

pub const Server = server.Server;
pub const Client = client.Client;
pub const Transport = transport.Transport;
pub const StdioTransport = transport.StdioTransport;
pub const BufferedTransport = transport.BufferedTransport;

test {
    std.testing.refAllDecls(@This());
}
