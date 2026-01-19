const std = @import("std");
const zen = @import("zen");

const log = std.log.scoped(.main);
const NUM_IO_WORKERS = 3;

const routes = [_]zen.http.router.Route{
    .{ .pattern = "/", .handlers = .{ .GET = index, .POST = post } },
};
const Config = zen.cfg.Config(struct {
    TCP_BIND: []const u8,
});
const ConfigGroup = zen.cfg.Group(.{
    .default = Config,
    .http = zen.http.server.DefaultConfig,
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
var instances: [NUM_IO_WORKERS]zen.AppInstance(App) = undefined;

fn index(req: *const zen.http.Request, res: *zen.http.Response) !void {
    _ = req;
    log.info("INDEX", .{});
    res.statusCode = .ok;
}

fn post(req: *const zen.http.Request, res: *zen.http.Response) !void {
    _ = req;
    log.info("POST", .{});
    res.statusCode = .ok;
}

pub fn main(init: std.process.Init) !void {
    defer log.info("done", .{});
    const allocator = init.gpa;
    // Currently requires multi-threaded I/O as there's no way to yield back to the I/O loop on single threaded system
    // https://gitlab.com/tadej3/zig-zen/-/issues/3
    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cfg = try zen.cfg.loadEnv(Config, allocator, init.minimal.environ);
    defer zen.cfg.deinit(Config, allocator, cfg);
    const groupCfg = ConfigGroup.from(.{
        .default = &cfg,
        .http = &zen.http.server.defaultCfg,
    });
    var ioGroup: std.Io.Group = .init;
    defer ioGroup.cancel(io);
    try zen.run(App, io, &ioGroup, groupCfg, &instances, .{ .ioWorkers = NUM_IO_WORKERS });
    defer zen.stop(App, &instances);
    try zen.zio.SignalHandler.register(io, &ioGroup, shutdown);
    try ioGroup.await(io);
}

fn shutdown() void {
    zen.stop(App, &instances);
}
