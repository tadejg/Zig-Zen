const std = @import("std");

pub fn Reference(comptime T: type, comptime ref: []const []const u8) type {
    return struct {
        pub const Type = T;
        /// Stores a comptime slice of field names which are followed during resolution to find the value
        pub const _ref = ref;

        pub fn resolve(obj: anytype) Type {
            const ObjType = @TypeOf(obj);
            if (@typeInfo(ObjType) != .@"struct") @compileError("Can't resolve reference to non-struct");
            return _resolve(Type, _ref[0], _ref[1..], obj);
        }
    };
}

pub fn Resolved(comptime ref: anytype) type {
    if (comptime isRef(ref)) return ref.Type;
    if (comptime isStructRef(ref)) return ref.__struct_type;
    @compileError("Not a reference");
}

pub fn resolve(comptime ref: anytype, obj: anytype) Resolved(ref) {
    if (comptime isRef(ref)) return ref.resolve(obj);
    if (comptime isStructRef(ref)) return resolveStruct(ref, obj);
    @compileError("Not a reference");
}

pub fn resolveStruct(comptime ref: anytype, obj: anytype) ref.__struct_type {
    const ObjType = @TypeOf(obj);
    if (@typeInfo(ObjType) != .@"struct") @compileError("Can't resolve reference to non-struct");
    return _resolve(ref.__struct_type, ref.__struct_ref[0], ref.__struct_ref[1..], obj);
}

fn _resolve(
    comptime T: type,
    comptime name: []const u8,
    comptime refStack: []const []const u8,
    obj: anytype,
) T {
    if (refStack.len == 0) return @field(obj, name);
    return _resolve(T, refStack[0], refStack[1..], @field(obj, name));
}

pub fn isAnyRef(comptime ref: anytype) bool {
    return isRef(ref) or isStructRef(ref);
}

pub fn isAnyRefOf(comptime ref: anytype, comptime T: type) bool {
    return isRefOf(ref, T) or isStructRefOf(ref, T);
}

pub fn isRefOf(comptime ref: anytype, comptime T: type) bool {
    return isRef(ref) and ref.Type == T;
}

pub fn isStructRefOf(comptime ref: anytype, comptime T: type) bool {
    return isStructRef(ref) and ref.__struct_type == T;
}

pub fn isStructRef(comptime ref: anytype) bool {
    const T = @TypeOf(ref);
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, "__struct_type") and @hasField(T, "__struct_ref"),
        else => false,
    };
}

pub fn isRef(comptime T: anytype) bool {
    if (@TypeOf(T) != type) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "_ref") and @hasDecl(T, "Type") and @hasDecl(T, "resolve"),
        else => false,
    };
}

pub fn resolveIfRef(comptime value: anytype, obj: anytype) if (isAnyRef(value)) Resolved(value) else @TypeOf(value) {
    if (comptime isAnyRef(value)) {
        return resolve(value, obj);
    } else {
        return value;
    }
}

pub fn References(comptime Spec: type) type {
    return StructReference(Spec, &.{});
}

fn StructReference(comptime T: type, refStack: []const []const u8) type {
    const fields = std.meta.fields(T);
    const numFields = fields.len + 2; // Extra fields to store metadata needed to resolve the entire struct as a ref
    comptime var fieldNames: []const []const u8 = &.{ "__struct_ref", "__struct_type" };
    comptime var fieldTypes: [numFields]type = undefined;
    comptime var fieldAttrs: [numFields]std.builtin.Type.StructField.Attributes = undefined;
    fieldTypes[0] = []const []const u8;
    fieldAttrs[0] = .{ .default_value_ptr = @ptrCast(@alignCast(&refStack)) };
    fieldTypes[1] = type;
    fieldAttrs[1] = .{ .default_value_ptr = &T };
    inline for (fields, 2..) |field, i| {
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
