const std = @import("std");
/// RFC doesn't impose a limit, but recommends less than 2048 as this is the limit in most practical cases
/// https://stackoverflow.com/a/417184
pub const MAX_PATH_LEN = 2048;
/// RPC doesn't impose a limit, but in practice, we don't often see them longer than 16 bytes
pub const MAX_METHOD_LEN = 16;
pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
    /// Used for non-standard methods
    unknown,

    pub fn parse(buff: []u8) @This() {
        inline for (std.meta.fields(@This())) |field| {
            if (std.mem.eql(u8, field.name, buff)) {
                return @field(@This(), field.name);
            }
        }
        return .unknown;
    }
};

method: Method = .unknown,
_rawMethod: [MAX_METHOD_LEN]u8 = .{0} ** MAX_METHOD_LEN,
rawMethod: []u8 = undefined,
_path: [MAX_PATH_LEN]u8 = .{0} ** MAX_PATH_LEN,
path: []u8 = undefined,
