//! Purely declarative, comptime-only app spec
pub fn App(comptime spec: anytype) type {
    const SpecType = @TypeOf(spec);
    if (@hasField(SpecType, "servers")) {
        validateServers(spec.servers);
    }
    return struct {
        pub const Spec = spec;
    };
}

fn validateServers(servers: anytype) void {
    _ = servers;
}
