const std = @import("std");
const zen = @import("zen");

const log = std.log.scoped(.main);
const routes = [_]zen.http.router.Route{
    .{ .pattern = "/", .handlers = .{ .GET = index, .POST = post } },
};

fn index(req: *const zen.http.Request, res: *zen.http.Response) !void {
    _ = req;
    std.log.info("INDEX", .{});
    res.statusCode = .ok;
}

fn post(req: *const zen.http.Request, res: *zen.http.Response) !void {
    _ = req;
    std.log.info("POST", .{});
    res.statusCode = .ok;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => log.err("Leak detected", .{}),
    };
    const allocator = gpa.allocator();
    // Currently requires multi-threaded I/O as there's no way to yield back to the I/O loop on single threaded system
    // https://gitlab.com/tadej3/zig-zen/-/issues/3
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const Config = zen.cfg.Config(struct {
        TCP_BIND: []const u8,
    });
    var cfg = try zen.cfg.loadEnv(Config, allocator);
    defer zen.cfg.deinit(Config, allocator, cfg);
    const ConfigGroup = zen.cfg.Group(.{
        .default = Config,
        .http = zen.http.server.DefaultConfig,
    });
    const groupCfg = ConfigGroup.from(.{
        .default = &cfg,
        .http = &zen.http.server.defaultCfg,
    });
    const Router = zen.http.router.ParamRouter(.{
        .routes = routes,
    }, .oneOrMore);
    const App = zen.App(.{
        .servers = .{
            zen.http.Server(.{
                .listen = ConfigGroup.lazy.default.TCP_BIND,
                .buffers = ConfigGroup.lazy.http.buffers,
                .connectionPool = ConfigGroup.lazy.http.connectionPool,
                .handleRequest = Router.handleRequest,
            }),
        },
    });
    try zen.run.sync(App, threaded.io(), groupCfg);
}
