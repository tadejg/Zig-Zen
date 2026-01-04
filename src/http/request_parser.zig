const std = @import("std");
const Request = @import("request.zig");
const RequestUriParser = @import("request_uri_parser.zig");

const Self = @This();

pub const State = enum {
    method,
    path,
    version,
    headerKey,
    headerValue,
    body,
    done,
};
const SEPARATORS = .{
    '(',
    ')',
    '<',
    '>',
    '@',
    ',',
    ';',
    ':',
    '\\',
    '"',
    '/',
    '[',
    ']',
    '{',
    '}',
    ' ',
    '\t',
};

state: State = .method,
uriParser: RequestUriParser,

pub const init: Self = .{ .uriParser = .init() };

pub const UpdateError = error{BadRequest};

fn isTokenChar(c: u8) bool {
    if (c < 33 or c > 126) return false;
    inline for (&SEPARATORS) |v| {
        if (c == v) return false;
    }
    return true;
}

pub fn update(self: *Self, req: *Request, buff: []const u8) UpdateError!void {
    for (buff) |b| {
        switch (self.state) {
            .method => {
                if (b == ' ') {
                    req.method = Request.Method.parse(req.rawMethod);
                    self.state = .path;
                } else if (isTokenChar(b)) {
                    if (req.rawMethod.len == req._rawMethod.len) return error.BadRequest;
                    req._rawMethod[req.rawMethod.len] = b;
                    req.rawMethod = req._rawMethod[0 .. req.rawMethod.len + 1];
                } else {
                    return error.BadRequest;
                }
            },
            .path => {
            },
            .version => {},
            .headerKey => {},
            .headerValue => {},
            .body => {},
            .done => {},
        }
    }
}
