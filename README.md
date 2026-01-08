# Zen

**Zero-allocation declarative Zig framework**

<hr/>

<!--toc:start-->
- [Zen](#zen)
  - [Usage](#usage)
  - [Building](#building)
  - [Testing](#testing)
  - [Architecture](#architecture)
  - [API Documentation](#api-documentation)
  - [Quick Start](#quick-start)
  - [Configuration](#configuration)
    - [Value Coercion](#value-coercion)
    - [Sources](#sources)
      - [Static](#static)
      - [System Environment](#system-environment)
      - [Dotenv Format](#dotenv-format)
      - [JSON](#json)
    - [Groups](#groups)
<!--toc:end-->

<hr/>

## Usage

Add Zen as a dependency:

```bash
zig fetch --save git+https://gitlab.com/tadej3/zig-zen.git
```

Link against Zen in your `build.zig`:

```zig
const zen = b.dependency("zen", .{ .target = target, .optimize = optimize });
mod.addImport("zen", zen.module("zen"));
```

## Building

```bash
zig build
```

## Testing

```bash
zig build test
```

## Architecture

Zen makes heavy use of Zig's comptime to generate application code from a declarative specification. Every Zen
application starts with a `zen.App(.{})` spec which describes the servers, background tasks, clients, and other
components which make up the application. The application can then be started with a runtime of choice (sync, async,
concurrent). At the core is the I/O reactor which listens for events and notifies the appropriate consumer.

## API Documentation

Zen API documentation can be found on [Gitlab Pages](https://docs.zigzen.dev) or built using `zig build docs`.

## Quick Start

```zig
const std = @import("std");
const zen = @import("zen");

const log = std.log.scoped(.main);

pub fn main() !void {
    // Setup an allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => log.err("Leak detected", .{}),
    };
    const allocator = gpa.allocator();
    // Pick your I/O
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    // Describe the shape of your config
    const Config = zen.cfg.Config(struct {
        TCP_BIND: []const u8,
    });
    // Load the configuration from your preferred source (env, dotenv file, json, ...)
    var cfg = try zen.cfg.loadEnv(Config, allocator);
    defer zen.cfg.deinit(Config, allocator, cfg);
    // Describe the application
    const App = zen.App(.{
        .servers = .{
            zen.tcp.Server(.{
                // Components may be configured with comptime-known values or lazy configuration references
                // .listen = "127.0.0.1:1355",
                .listen = Config.lazy.TCP_BIND,
            }),
        },
    });
    // Pick your runtime and start the reactor!
    try zen.run.sync(App, threaded.io(), cfg);
}
```

## Configuration

The configuration component supports different sources, like the system environment, dotenv file format, json, ... A
configuration is first described as a struct - exact restrictions depend on the source, see below.

> **NOTE:** Not all sources support zero-allocation

```zig
const Config = zen.cfg.Config(struct {
    STRING: []const u8,
    NUMBER: u32,
    BOOL: bool,
    ARRAY: [3]f64,
});
// Use lazy references to configure your app components. These get resolved to actual values during runtime
zen.tcp.Server(.{ .listen = Config.lazy.STRING })
```

After describing the configuration shape, load it from your favorite source.

```zig
var cfg = try zen.cfg.loadEnv(Config, allocator);
defer zen.cfg.deinit(Config, allocator, cfg);
// Access the loaded values
cfg.value.STRING;
cfg.value.NUMBER;
cfg.value.BOOL;
cfg.value.ARRAY;
```

### Value Coercion

When values are loaded during runtime, their type is coerced to match the requested shape. The only exception to this
rule is `zen.cfg.static()` which allows any datatype and doesn't perform any coercion. Otherwise, supported data types
are strings, numbers (int and float), bool, array, slice, optional. The difference between arrays and slices is simply
that arrays must contain the exact number of elements specified in the config description, while slices behave like
variable length arrays.

> **NOTE:** Formats which don't natively support arrays or slices use a comma separated string of values instead.
> When bools aren't supported, case-insensitive strings "true", "1", "false", "0" may be used.

### Sources

#### Static

Allows you to wrap an existing object into a `Config` instance. A shallow copy of the object is made. No allocations
take place, caller is responsible for managing object's lifecycle. Consequently, calling `zen.cfg.deinit(Config,
allocator, cfg)` is completely optional, but not invalid.

> This source has no limitations on the configuration shape

```zig
const Config = zen.cfg.Config(struct {
    abc: []const u8,
});
var cfg = zen.cfg.static(Config, .{ .abc = "hello" });
defer zen.cfg.deinit(Config, allocator, cfg); // Optional
std.debug.print("{s}\n", .{ cfg.value.abc });
```

#### System Environment

Configuration can be loaded from system environment variables, though this always requires allocation. Config field
names are matched against environment variable names and values are coerced to the requested type.

> This source doesn't support nesting

```zig
const Config = zen.cfg.Config(struct {
    PWD: []const u8,
});
var cfg = try zen.cfg.loadEnv(Config, allocator);
defer zen.cfg.deinit(Config, allocator, cfg);
std.debug.print("{s}\n", .{ cfg.value.PWD });
```

#### Dotenv Format

Similar to the [system environment source](#system-environment), except values are loaded from a dotenv string.

> Generally, this source is zero-allocation, except when loading slices, however the input string must outlive the
> config instance.

String loaded from a `.env` file:
```
ABC=123
DEF=foo
```

```zig
const Config = zen.cfg.Config(struct {
    ABC: u16,
    DEF: []const u8,
});
const dotenv = "..."; // e.g. load this from a file
var cfg = try zen.cfg.loadDotEnv(Config, dotenv);
defer zen.cfg.deinit(Config, allocator, cfg);
std.debug.print("{d} {s}\n", .{ cfg.value.ABC, cfg.value.DEF });
```

#### JSON

JSON can be used for more complex configurations as it supports nesting and native arrays/slices and bools.

```zig
const Config = zen.cfg.Config(struct {
    abc: u16,
    def: struct { foo: bool, bar: []i32, baz: []const u8 },
});
// Configure components with lazy references to nested fields
... = Config.lazy.def.bar;
// ...or pass the entire nested object
... = Config.lazy.def;
const json = "..."; // e.g. load this from a file
var cfg = try zen.cfg.loadJson(Config, allocator, json);
defer zen.cfg.deinit(Config, allocator, cfg);
std.debug.print("{d} {s}\n", .{ cfg.value.abc, cfg.value.def.baz });
```

### Groups

Sometimes, configuration is loaded from multiple sources, but the runtime accepts a single config. Multiple
configurations may be merged into one using a `Group()`. The shape of the type returned by `Group()` is identical to the
shape of a `Config()`, meaning groups can be merged as well.

> **NOTE:** The group only performs a shallow copy of each config

```zig
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
    // Create the default config and load it from the system environment
    const Config = zen.cfg.Config(struct { TCP_BIND: []const u8 });
    var cfg = try zen.cfg.loadEnv(Config, allocator);
    defer zen.cfg.deinit(Config, allocator, cfg);
    // Create a static config for http buffers
    const HttpBuffersConfig = zen.cfg.Config(zen.http.ClientBuffers);
    const httpBuffersCfg = HttpBuffersConfig.static(.{
        .readBuffer = .{ .data = &readBuffer, .freeStack = &readBufferFreeStack, .chunkSize = BUFF_LEN },
        .writeBuffer = .{ .data = &writeBuffer, .freeStack = &writeBufferFreeStack, .chunkSize = BUFF_LEN },
    });
    // Create a combined type of the two configs, assigning a name to each
    const ConfigGroup = zen.cfg.Group(.{
        .default = Config,
        .http = HttpBuffersConfig,
    });
    // Use the combined type to merge the two loaded configs at runtime
    const groupCfg = ConfigGroup.from(.{
        .default = &cfg,
        .http = &httpBuffersCfg,
    });
    const App = zen.App(.{
        .servers = .{
            zen.http.Server(.{
                // Configure your app using lazy references to the group config
                .listen = ConfigGroup.lazy.default.TCP_BIND,
                .buffers = ConfigGroup.lazy.http,
            }),
        },
    });
    // Start the app using the group config
    try zen.run.sync(App, threaded.io(), groupCfg);
}
```
