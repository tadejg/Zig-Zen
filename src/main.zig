const std = @import("std");
const zen = @import("zen");

const log = std.log.scoped(.main);
const BUFF_LEN = 8 * 1024;
const MAX_CONN = 128;

var readBuffer = [_]u8{0} ** (MAX_CONN * BUFF_LEN);
var readBufferFreeStack = [_]u32{0} ** MAX_CONN;
var writeBuffer = [_]u8{0} ** (MAX_CONN * BUFF_LEN);
var writeBufferFreeStack = [_]u32{0} ** MAX_CONN;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => log.err("Leak detected", .{}),
    };
    const allocator = gpa.allocator();
    var threaded = std.Io.Threaded.init(allocator);
    defer threaded.deinit();
    const Config = zen.cfg.Config(struct {
        TCP_BIND: []const u8,
    });
    var cfg = try Config.loadEnv(allocator);
    defer cfg.deinit(allocator);
    const HttpBuffersConfig = zen.cfg.Config(zen.http.ClientBuffers);
    const httpBuffersCfg = HttpBuffersConfig.static(.{
        .readBuffer = .{ .data = &readBuffer, .freeStack = &readBufferFreeStack, .chunkSize = BUFF_LEN },
        .writeBuffer = .{ .data = &writeBuffer, .freeStack = &writeBufferFreeStack, .chunkSize = BUFF_LEN },
    });
    const ConfigGroup = zen.cfg.Group(.{
        .default = Config,
        .http = HttpBuffersConfig,
    });
    const groupCfg = ConfigGroup.from(.{
        .default = &cfg,
        .http = &httpBuffersCfg,
    });
    const App = zen.App(.{
        .servers = .{
            zen.http.Server(.{
                // .listen = "127.0.0.1:1355",
                .listen = ConfigGroup.lazy.default.TCP_BIND,
                .buffers = ConfigGroup.lazy.http,
            }),
        },
    });
    try zen.run.sync(App, threaded.io(), groupCfg);
}
