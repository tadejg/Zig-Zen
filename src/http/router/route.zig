const RequestHandler = @import("../server.zig").RequestHandler;
const Request = @import("../request.zig");

/// Set to .unknown to call the handler for request any method
method: Request.Method,
pattern: []const u8,
handler: RequestHandler,
