# Zen

**Zero-allocation declarative Zig framework**

<hr/>

## Building

```
zig build
```

## Architecture

Zen makes heavy use of Zig's comptime to generate application code from a declarative specification. Every Zen
application starts with a `zen.App(.{})` spec which describes the servers, background tasks, clients, and other
components which make up the application. The application can then be started with a runtime of choice (sync, async,
concurrent). At the core is the I/O reactor which listens for events and notifies the appropriate consumer.

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
    var threaded = std.Io.Threaded.init_single_threaded;
    // Describe the shape of your config
    const Config = zen.cfg.Config(struct {
        TCP_BIND: []const u8,
    });
    // Load the configuration from your preferred source (env, dotenv file, json, ...)
    var cfg = try Config.loadEnv(allocator);
    defer cfg.deinit(allocator);
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
var cfg = try Config.loadEnv(allocator);
defer cfg.deinit(allocator);
// Access the loaded values
cfg.value.STRING;
cfg.value.NUMBER;
cfg.value.BOOL;
cfg.value.ARRAY;
```

### Value Coercion

When values are loaded during runtime, their type is coerced to match the requested shape. The only exception to this
rule is `Config.static()` which allows any datatype and doesn't perform any coercion. Otherwise, supported data types
are strings, numbers (int and float), bool, array, slice, optional. The difference between arrays and slices is simply
that arrays must contain the exact number of elements specified in the config description, while slices behave like
variable length arrays.

> **NOTE:** Formats which don't natively support arrays or slices use a comma separated string of values instead.
> When bools aren't supported, case-insensitive strings "true", "1", "false", "0" may be used.

### Sources

#### Static

Allows you to wrap an existing object into a `Config` instance. A shallow copy of the object is made. No allocations
take place, caller is responsible for managing object's lifecycle. Consequently, calling `cfg.deinit(allocator)` is
completely optional, but not invalid.

> This source has no limitations on the configuration shape

```zig
const Config = zen.cfg.Config(struct {
    abc: []const u8,
});
var cfg = Config.static(.{ .abc = "hello" });
defer cfg.deinit(allocator); // Optional
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
var cfg = try Config.loadEnv(allocator);
defer cfg.deinit(allocator);
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
var cfg = try Config.loadDotEnv(dotenv);
defer cfg.deinit(allocator);
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
var cfg = try Config.loadJson(json);
defer cfg.deinit(allocator);
std.debug.print("{d} {d}\n", .{ cfg.value.abc, cfg.value.def.baz });
```
