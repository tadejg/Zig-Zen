const std = @import("std");
const ref = @import("reference.zig");

pub fn Group(comptime configs: anytype) type {
    const Type = @TypeOf(configs);
    const typeInfo = @typeInfo(Type);
    if (typeInfo != .@"struct" or typeInfo.@"struct".is_tuple) {
        @compileError("Group configs must be a struct");
    }
    const numFields = typeInfo.@"struct".fields.len;
    var fieldNames: []const []const u8 = &.{};
    var fieldTypes: [numFields]type = .{undefined} ** numFields;
    var fieldAttrs: [numFields]std.builtin.Type.StructField.Attributes = .{undefined} ** numFields;
    inline for (typeInfo.@"struct".fields, 0..) |field, i| {
        const CfgType = @field(configs, field.name);
        if (!@hasDecl(CfgType, "Spec") or !@hasDecl(CfgType, "lazy")) {
            @compileError("Group configs must be instances of the Config() generic type");
        }
        fieldNames = fieldNames ++ .{field.name};
        fieldTypes[i] = CfgType.Spec;
        fieldAttrs[i] = .{};
    }
    const GroupSpec = @Struct(.auto, null, fieldNames, &fieldTypes, &fieldAttrs);
    return struct {
        pub const Spec = GroupSpec;
        pub const lazy: ref.References(Spec) = .{};

        pub fn from(instances: anytype) Instance {
            const InstancesType = @TypeOf(instances);
            const instancesTypeInfo = @typeInfo(InstancesType);
            if (instancesTypeInfo != .@"struct" or instancesTypeInfo.@"struct".is_tuple) {
                @compileError("Group instances must be a struct");
            }
            var value: Spec = undefined;
            inline for (std.meta.fields(Spec)) |field| {
                if (!@hasField(InstancesType, field.name)) {
                    @compileError("Config '" ++ field.name ++ "' missing from group");
                }
                @field(value, field.name) = @field(instances, field.name).value;
            }
            return .{ .value = value };
        }

        pub const Instance = struct {
            value: Spec,
        };
    };
}
