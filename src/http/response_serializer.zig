const std = @import("std");
const Response = @import("response.zig");
const status = @import("status.zig");

const Self = @This();
const STATUS_CODE_LEN = 3;
const SPACE = " ";
const CRLF = "\r\n";
const VERSION = "HTTP/1.1";

const State = enum {
    init,
    version,
    statusCode,
    statusMessage,
    headers, // TODO
    body, // TODO
    space,
    crlf,
    done,
};

res: *const Response,
state: State = .init,
nextState: State = .init,
reader: std.Io.Reader,
statusCode: [STATUS_CODE_LEN]u8 = .{0} ** STATUS_CODE_LEN,
versionWritten: u4 = 0,
statusCodeWritten: u2 = 0,
statusMessageWritten: u6 = 0,
crlfWritten: u2 = 0,

/// Takes a buffer used for the returned reader
pub fn init(res: *const Response, buffer: []u8) Self {
    return .{
        .res = res,
        .reader = .{
            .buffer = buffer,
            .end = 0,
            .seek = 0,
            .vtable = &.{
                .stream = stream,
            },
        },
    };
}

fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *Self = @fieldParentPtr("reader", reader);
    var written: usize = 0;
    switch (self.state) {
        .init => {
            const out = std.fmt.bufPrint(&self.statusCode, "{d}", .{@intFromEnum(self.res.statusCode)}) catch {
                return error.ReadFailed;
            };
            // HTTP status codes are always 3 digits (100-999)
            std.debug.assert(out.len == STATUS_CODE_LEN);
            self.state = .version;
        },
        .version => {
            written = try writer.write(limit.sliceConst(VERSION[self.versionWritten..]));
            self.versionWritten += @intCast(written);
            if (self.versionWritten == VERSION.len) {
                self.nextState = .statusCode;
                self.state = .space;
            }
        },
        .statusCode => {
            written = try writer.write(limit.sliceConst(self.statusCode[self.statusCodeWritten..]));
            self.statusCodeWritten += @intCast(written);
            if (self.statusCodeWritten == STATUS_CODE_LEN) {
                self.nextState = .statusMessage;
                self.state = .space;
            }
        },
        .statusMessage => {
            const msg = status.message(self.res.statusCode);
            written = try writer.write(limit.sliceConst(msg[self.statusMessageWritten..]));
            self.statusMessageWritten += @intCast(written);
            if (self.statusMessageWritten == msg.len) {
                self.nextState = .headers;
                self.state = .crlf;
            }
        },
        .headers => {
            // TODO
            self.nextState = .body;
            self.state = .crlf;
        },
        .body => {
            self.state = .done;
        },
        .space => {
            written = try writer.write(limit.sliceConst(SPACE));
            if (written == SPACE.len) self.state = self.nextState;
        },
        .crlf => {
            written = try writer.write(limit.sliceConst(CRLF[self.crlfWritten..]));
            self.crlfWritten += @intCast(written);
            if (self.crlfWritten == CRLF.len) {
                self.state = self.nextState;
                self.crlfWritten = 0;
            }
        },
        .done => return error.EndOfStream,
    }
    return written;
}
