//! This parser currently doesn't produce any output apart from the `out` slice, containing the full URI, which points
//! into `buff`. It currently serves more of a validation role and doesn't implement the full RFC - only what the HTTP
//! server needs to handle to cover most general cases. Mainly, fragments aren't supported as the server should never
//! receive them
const std = @import("std");

const Self = @This();

pub const State = enum {
    start,
    scheme,
    scheme_sep_1,
    scheme_sep_2,
    host,
    host_hostname,
    host_ipv4,
    host_ipv6,
    port,
    path,
    query,
    authority,
    escape_seq,
    done,
};

pub const Type = enum {
    origin,
    absolute,
    authority,
    asterisk,
};

const SCHEME_SYMBOLS: []const u8 = &.{ '+', '-', '.' };
const MARK: []const u8 = &.{ '-', '_', '.', '!', '~', '*', '\'', '(', ')' };
const REG_SYMBOLS: []const u8 = &.{ '$', ',', ';', ':', '@', '&', '=', '+' };
const PATH_SYMBOLS: []const u8 = &.{ ';', ':', '@', '&', '=', '+', '$', ',', '/' };
const RESERVED_SYMBOLS: []const u8 = &.{ ';', '/', '?', ':', '@', '&', '=', '+', '$', ',' };

state: State = .start,
/// Used by .escape_seq state
prevState: State = .start,
uriType: Type = undefined,
/// Set this to true when request method is CONNECT
allowRegNameAuthority: bool = false,
hostLen: u32 = 0,
hostMayBeHostname: bool = true,
hostMayBeIpv4: bool = true,
hostMayBeIpv6: bool = true,
nIpv4Segments: u8 = 0,
nIpv6Segments: u8 = 0,
escapeIdx: u2 = 0,

pub const init: Self = .{};

pub const UpdateError = error{MalformedUri};

pub fn update(self: *Self, byte: u8, buff: []u8, out: *[]u8) UpdateError!void {
    buff[out.len] = byte;
    out.* = buff[0 .. out.len + 1];
    switch (self.state) {
        .start => {
            if (byte == '*') {
                self.uriType = .asterisk;
                self.state = .done;
            } else if (byte == '/') {
                self.uriType = .origin;
                self.state = .path;
            } else if (std.ascii.isAlphabetic(byte)) {
                self.uriType = .absolute;
                self.state = .scheme;
            } else if (self.allowRegNameAuthority) {
                self.uriType = .authority;
                self.state = .authority;
            } else return error.MalformedUri;
        },
        .scheme => {
            if (byte == ':') {
                self.state = .scheme_sep_1;
            } else if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, SCHEME_SYMBOLS, byte) == null) {
                return error.MalformedUri;
            }
        },
        .scheme_sep_1 => {
            if (byte != '/') return error.MalformedUri;
            self.state = .scheme_sep_2;
        },
        .scheme_sep_2 => {
            if (byte != '/') return error.MalformedUri;
            self.state = .host;
        },
        .host => blk: {
            const prevByte = out.*[out.len - 2];
            self.hostLen += 1;
            if (self.hostLen == 1 and byte == '[') {
                self.state = .host_ipv6;
                break :blk;
            }
            if (!std.ascii.isAlphanumeric(byte) and byte != ':' and byte != '.') {
                return error.MalformedUri;
            }
            if ((self.hostLen == 1 and byte == '-') or (!std.ascii.isAlphanumeric(byte) and byte != '-')) {
                self.hostMayBeHostname = false;
            }
            const startsWithDot = (self.hostLen == 1 and byte == '.');
            if ((!std.ascii.isDigit(byte) and byte != '.') or startsWithDot or (prevByte == '.' and byte == '.')) {
                self.hostMayBeIpv4 = false;
            }
            const startsWithColon = (self.hostLen == 1 and byte == ':');
            if ((!std.ascii.isHex(byte) and byte != ':') or startsWithColon or (prevByte == ':' and byte == ':')) {
                self.hostMayBeIpv6 = false;
            }
            if (self.hostMayBeIpv4 and byte == '.') {
                self.nIpv4Segments += 1;
            }
            if (self.hostMayBeIpv6 and byte == ':') {
                self.nIpv6Segments += 1;
            }
            if (self.hostMayBeHostname and !self.hostMayBeIpv4 and !self.hostMayBeIpv6) {
                self.state = .host_hostname;
            } else if (!self.hostMayBeHostname and self.hostMayBeIpv4 and !self.hostMayBeIpv6) {
                self.state = .host_ipv4;
            } else if (!self.hostMayBeHostname and !self.hostMayBeIpv4 and self.hostMayBeIpv6) {
                self.state = .host_ipv6;
            } else if (!self.hostMayBeHostname and !self.hostMayBeIpv4 and !self.hostMayBeIpv6) {
                return error.MalformedUri;
            }
        },
        .host_hostname => {
            if (byte == ':') {
                self.state = .port;
            } else if (byte == '/') {
                self.state = .path;
            } else if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') {
                return error.MalformedUri;
            }
        },
        .host_ipv4 => {
            const prevByte = out.*[out.len - 2];
            if (byte == ':') {
                if (prevByte == '.') return error.MalformedUri;
                self.state = .port;
            } else if (byte == '/') {
                if (prevByte == '.') return error.MalformedUri;
                self.state = .path;
            } else if (!std.ascii.isDigit(byte) and byte != '.') {
                return error.MalformedUri;
            }
            if (byte == '.') {
                self.nIpv4Segments += 1;
                if (self.nIpv4Segments > 3) return error.MalformedUri;
            }
        },
        .host_ipv6 => {
            const prevByte = out.*[out.len - 2];
            if (prevByte == ']' and byte == ':') {
                self.state = .port;
            } else if (byte == '/') {
                self.state = .path;
            } else if (!std.ascii.isHex(byte) and byte != ':' and byte != ']') {
                return error.MalformedUri;
            }
            if (prevByte != ']' and byte == ':') {
                self.nIpv6Segments += 1;
                if (self.nIpv6Segments > 7) return error.MalformedUri;
            }
        },
        .port => {
            if (byte == '/') {
                self.state = .path;
            } else if (!std.ascii.isDigit(byte)) {
                return error.MalformedUri;
            }
        },
        .path => blk: {
            if (byte == '%') {
                self.prevState = self.state;
                self.state = .escape_seq;
                break :blk;
            }
            if (byte == '?') {
                self.state = .query;
                break :blk;
            }
            const notMark = std.mem.findScalar(u8, MARK, byte) == null;
            const notPathSymbols = std.mem.findScalar(u8, PATH_SYMBOLS, byte) == null;
            if (!std.ascii.isAlphanumeric(byte) and notMark and notPathSymbols) {
                return error.MalformedUri;
            }
        },
        .query => blk: {
            if (byte == '%') {
                self.prevState = self.state;
                self.state = .escape_seq;
                break :blk;
            }
            const notMark = std.mem.findScalar(u8, MARK, byte) == null;
            const notReserved = std.mem.findScalar(u8, RESERVED_SYMBOLS, byte) == null;
            if (!std.ascii.isAlphanumeric(byte) and notMark and notReserved) {
                return error.MalformedUri;
            }
        },
        .authority => blk: {
            if (byte == '%') {
                self.prevState = self.state;
                self.state = .escape_seq;
                break :blk;
            }
            const notMark = std.mem.findScalar(u8, MARK, byte) == null;
            const notRegSymbols = std.mem.findScalar(u8, REG_SYMBOLS, byte) == null;
            if (!std.ascii.isAlphanumeric(byte) and notMark and notRegSymbols) {
                return error.MalformedUri;
            }
        },
        .escape_seq => {
            if (!std.ascii.isHex(byte)) {
                return error.MalformedUri;
            }
            self.escapeIdx += 1;
            if (self.escapeIdx == 2) {
                self.state = self.prevState;
            }
        },
        .done => out.* = out.*[0 .. out.len - 1],
    }
}

test "should parse asterisk" {
    const input = "*";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse root path" {
    const input = "/";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse an absolute path" {
    const input = "/foo/bar";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse an absolute path with query" {
    const input = "/foo/bar?foobar=baz&abc=42";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse a full URL" {
    const input = "http://foobar.baz/abc/def/?query";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse a full URL with encoded characters" {
    const input = "http://foobar.baz/abc/d%20ef/?qu%20ery";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse a URL with IPv4" {
    const input = "http://111.2.33.44/abc/def/?query";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse a URL with IPv4 and port" {
    const input = "http://111.2.33.44:8080/abc/def/?query";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should fail to parse a URL with invalid number of IPv4 segments" {
    const err = struct {
        pub fn doTest() !void {
            const input = "http://111.2.33.44.555/abc/def/?query";
            var parser = Self.init;
            var buff = [_]u8{0} ** input.len;
            var out: []u8 = "";
            for (input) |c| try parser.update(c, &buff, &out);
        }
    }.doTest();
    try std.testing.expectError(error.MalformedUri, err);
}

test "should fail to parse a URL with incomplete IPv4" {
    const err = struct {
        pub fn doTest() !void {
            const input = "http://111.2.33./abc/def/?query";
            var parser = Self.init;
            var buff = [_]u8{0} ** input.len;
            var out: []u8 = "";
            for (input) |c| try parser.update(c, &buff, &out);
        }
    }.doTest();
    try std.testing.expectError(error.MalformedUri, err);
}

test "should parse a URL with IPv6" {
    const input = "http://3f2a:9c4e:7b10:0d8a:5e6f:1c2b:a901:4f3d/abc/def/?query";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should parse a URL with IPv6 and port" {
    const input = "http://[3f2a:9c4e:7b10:0d8a:5e6f:1c2b:a901:4f3d]:8080/abc/def/?query";
    var parser = Self.init;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should fail to parse a URL with invalid number of IPv6 segments" {
    const err = struct {
        pub fn doTest() !void {
            const input = "http://3f2a:9c4e:7b10:0d8a:5e6f:1c2b:a901:4f3d:fff/abc/def/?query";
            var parser = Self.init;
            var buff = [_]u8{0} ** input.len;
            var out: []u8 = "";
            for (input) |c| try parser.update(c, &buff, &out);
        }
    }.doTest();
    try std.testing.expectError(error.MalformedUri, err);
}

test "should parse a reg_name" {
    const input = "-123foo%20bar";
    var parser = Self.init;
    parser.allowRegNameAuthority = true;
    var buff = [_]u8{0} ** input.len;
    var out: []u8 = "";
    for (input) |c| try parser.update(c, &buff, &out);
    try std.testing.expectEqualStrings(input, out);
}

test "should fail to parse a reg_name when not explicitly allowed" {
    const err = struct {
        pub fn doTest() !void {
            const input = "-123foo%20bar";
            var parser = Self.init;
            var buff = [_]u8{0} ** input.len;
            var out: []u8 = "";
            for (input) |c| try parser.update(c, &buff, &out);
        }
    }.doTest();
    try std.testing.expectError(error.MalformedUri, err);
}
