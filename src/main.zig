const std = @import("std");
const zen = @import("zen");

const log = std.log.scoped(.main);

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
    const App = zen.App(.{
        .servers = .{
            zen.tcp.Server(.{
                // .listen = "127.0.0.1:1355",
                .listen = Config.lazy.TCP_BIND,
            }),
        },
    });
    try zen.run(App, threaded.io(), cfg);
}
