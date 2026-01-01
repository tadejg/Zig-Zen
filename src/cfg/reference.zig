const std = @import("std");

pub fn Reference(comptime T: type, comptime ref: []const []const u8) type {
    return struct {
        pub const Type = T;
        /// Stores a comptime slice of field names which are followed during resolution to find the value
        pub const _ref = ref;

        pub fn resolve(obj: anytype) Type {
            const ObjType = @TypeOf(obj);
            if (@typeInfo(ObjType) != .@"struct") @compileError("Can't resolve reference to non-struct");
            return _resolve(_ref[0], _ref[1..], obj);
        }

        fn _resolve(
            comptime name: []const u8,
            comptime refStack: []const []const u8,
            obj: anytype,
        ) Type {
            if (refStack.len == 0) return @field(obj, name);
            return _resolve(refStack[0], refStack[1..], @field(obj, name));
        }
    };
}

pub fn isRef(comptime T: anytype) bool {
    if (@TypeOf(T) != type) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "_ref") and @hasDecl(T, "Type") and @hasDecl(T, "resolve"),
        else => false,
    };
}

pub fn resolveIfRef(comptime value: anytype, obj: anytype) if (isRef(value)) value.Type else @TypeOf(value) {
    if (comptime isRef(value)) {
        return value.resolve(obj);
    } else {
        return value;
    }
}

pub fn References(comptime Spec: type) type {
    return StructReference(Spec, &.{});
}

fn StructReference(comptime T: type, refStack: []const []const u8) type {
    const fields = std.meta.fields(T);
    comptime var fieldNames: []const []const u8 = &.{};
    comptime var fieldTypes: [fields.len]type = undefined;
    comptime var fieldAttrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (fields, 0..) |field, i| {
        var typeInfo = @typeInfo(field.type);
        if (typeInfo == .optional) typeInfo = @typeInfo(typeInfo.optional.child);
        fieldNames = fieldNames ++ .{field.name};
        switch (typeInfo) {
            .int, .float, .bool, .@"enum", .array, .pointer => {
                fieldTypes[i] = type;
                fieldAttrs[i] = .{ .default_value_ptr = &Reference(field.type, refStack ++ .{field.name}) };
            },
            .@"struct" => {
                fieldTypes[i] = StructReference(field.type, refStack ++ .{field.name});
                fieldAttrs[i] = .{ .default_value_ptr = &fieldTypes[i]{} };
            },
            else => @compileError("Unsupported reference field type " ++ @typeName(field.type)),
        }
    }
    return @Struct(
        .auto,
        null,
        fieldNames,
        &fieldTypes,
        &fieldAttrs,
    );
}
