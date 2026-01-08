const std = @import("std");
const zio = @import("../zio/root.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const RequestParser = @import("request_parser.zig");
const ResponseSerializer = @import("response_serializer.zig");

socket: zio.Socket,
ip: std.Io.net.IpAddress,
readBuffer: []u8,
writeBuffer: []u8,
handler: zio.Reactor.Handler,
server: *anyopaque,
node: std.SinglyLinkedList.Node = .{},
req: Request,
res: Response,
reqParser: RequestParser = .init,
resSerializer: ResponseSerializer,
