const std = @import("std");
const zio = @import("../zio/root.zig");
const Request = @import("request.zig");
const RequestParser = @import("request_parser.zig");

socket: zio.Socket,
ip: std.Io.net.IpAddress,
readBuffer: []u8,
writeBuffer: []u8,
writeBufferStart: usize = 0,
writeBufferEnd: usize = 0,
handler: zio.Reactor.Handler,
server: *anyopaque,
node: std.SinglyLinkedList.Node = .{},
req: Request,
reqParser: RequestParser = .init,
