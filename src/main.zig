const std = @import("std");
const zen = @import("zen");

const log = std.log.scoped(.main);
const routes = [_]zen.http.router.Route{
    .{ .method = .GET, .pattern = "/", .handler = index },
    .{ .method = .POST, .pattern = "/", .handler = post },
};

fn index(req: *const zen.http.Request) !zen.http.Response {
    _ = req;
    return .{ .statusCode = .ok };
}

fn post(req: *const zen.http.Request) !zen.http.Response {
    _ = req;
    return .{ .statusCode = .ok };
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => log.err("Leak detected", .{}),
    };
    const allocator = gpa.allocator();
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
    });
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
