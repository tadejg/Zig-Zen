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
const VERSION = "HTTP/1.1";
const HARD_HEADER_LEN_LIMIT = 4096;

state: State = .method,
uriParser: RequestUriParser,
versionIdx: u8 = 0,
lastHeaderLineLen: u32 = 0,

pub const init: Self = .{ .uriParser = .init };

pub const UpdateError = error{BadRequest} || RequestUriParser.UpdateError;

fn isTokenChar(c: u8) bool {
    if (c < 33 or c > 126) return false;
    inline for (&SEPARATORS) |v| {
        if (c == v) return false;
    }
    return true;
}

pub fn isDone(self: *const Self) bool {
    return self.state == .done;
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
                if (b == ' ') {
                    self.state = .version;
                } else {
                    try self.uriParser.update(b, &req._path, &req.path);
                }
            },
            .version => blk: {
                if (self.versionIdx == VERSION.len) {
                    if (b == '\r') {
                        break :blk;
                    } else if (b == '\n') {
                        self.state = .headerKey;
                        break :blk;
                    } else return error.BadRequest;
                } else if (VERSION[self.versionIdx] != b) {
                    return error.BadRequest;
                }
                self.versionIdx += 1;
            },
            .headerKey => blk: {
                if (self.lastHeaderLineLen >= HARD_HEADER_LEN_LIMIT) {
                    return error.BadRequest;
                }
                if (b == '\n' and self.lastHeaderLineLen == 0) {
                    self.state = .done;
                    break :blk;
                } else if (b == ':') {
                    self.state = .headerValue;
                } else if (!isTokenChar(b)) {
                    return error.BadRequest;
                }
                self.lastHeaderLineLen += 1;
                // TODO Store headers
            },
            .headerValue => blk: {
                if (self.lastHeaderLineLen >= HARD_HEADER_LEN_LIMIT) {
                    return error.BadRequest;
                }
                if (b == '\r') {
                    self.lastHeaderLineLen = 0;
                    self.state = .headerKey;
                    break :blk;
                } else if (!std.ascii.isPrint(b)) {
                    return error.BadRequest;
                }
                self.lastHeaderLineLen += 1;
                // TODO Store headers
            },
            .done => {},
        }
    }
}
