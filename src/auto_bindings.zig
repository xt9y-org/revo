//! Automatic Revo bindings for ordinary Zig functions.
//! Generated at comptime; no per-function Revo declarations or hand-written wrappers.
//! Only signatures representable safely by Revo are exported. Unsupported
//! declarations are skipped, including slices, callbacks, structs and generics.
const std = @import("std");
const revo = @import("root.zig");
const ext = @import("extension.zig");
const Value = ext.Value;
const VM = ext.VM;
const HostResult = ext.HostResult;

fn isCString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == u8 and p.is_const and (p.size == .c or p.size == .many),
        else => false,
    };
}

fn supported(comptime T: type, comptime is_return: bool) bool {
    return switch (@typeInfo(T)) {
        .void => is_return,
        .bool => true,
        .int => |i| i.bits <= 64,
        .float => |f| f.bits <= 64,
        .@"enum" => |e| @typeInfo(e.tag_type).int.bits <= 64,
        .pointer => |p| p.size != .slice and @typeInfo(p.child) != .@"fn",
        .optional => |o| supported(o.child, is_return) and switch (@typeInfo(o.child)) {
            .pointer => true,
            else => false,
        },
        .error_union => |e| is_return and supported(e.payload, true),
        else => false,
    };
}

fn supportedFn(comptime T: type) bool {
    if (@typeInfo(T) != .@"fn") return false;
    const f = @typeInfo(T).@"fn";
    if (f.is_generic or f.is_var_args or f.param_types.len > ext.max_params) return false;
    if (f.return_type == null or !supported(f.return_type.?, true)) return false;
    for (f.param_types) |p| {
        if (p == null or !supported(p.?, false)) return false;
    }
    return true;
}

fn count(comptime Namespace: type) usize {
    var n: usize = 0;
    for (@typeInfo(Namespace).@"struct".decl_names) |name| {
        if (supportedFn(@TypeOf(@field(Namespace, name)))) n += 1;
    }
    return n;
}

fn paramType(comptime T: type) ext.ParamType {
    if (isCString(T)) return .string;
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int, .float, .@"enum" => .number,
        else => .any,
    };
}

fn isNil(value: Value) bool {
    return value.asAtom() == revo.CoreAtoms.atomId(.nil);
}

fn decode(comptime T: type, value: Value, vm: *VM, temp: *?[:0]u8) !T {
    switch (@typeInfo(T)) {
        .bool => {
            const id = value.asAtom() orelse return error.ExpectedBoolean;
            if (id == revo.CoreAtoms.atomId(.true)) return true;
            if (id == revo.CoreAtoms.atomId(.false)) return false;
            return error.ExpectedBoolean;
        },
        .int => return ext.numToInt(T, value.asNumOpt() orelse return error.ExpectedNumber) orelse error.IntegerOutOfRange,
        .float => return @floatCast(value.asNumOpt() orelse return error.ExpectedNumber),
        .@"enum" => |e| {
            const n = ext.numToInt(e.tag_type, value.asNumOpt() orelse return error.ExpectedNumber) orelse return error.IntegerOutOfRange;
            return @enumFromInt(n);
        },
        .pointer => {
            if (comptime isCString(T)) {
                const id = value.asString() orelse return error.ExpectedString;
                const bytes = vm.stringValue(id);
                temp.* = try vm.runtime.alloc.dupeSentinel(u8, bytes, 0);
                return @ptrCast(temp.*.?.ptr);
            }
            if (isNil(value)) {
                if (@typeInfo(T).pointer.size == .c) return @ptrFromInt(0);
                return error.NullPointer;
            }
            const ptr = ext.resourcePtr(vm, value) orelse value.asOpaque() orelse return error.ExpectedPointer;
            return @ptrFromInt(@intFromPtr(ptr));
        },
        .optional => |o| {
            if (isNil(value)) return null;
            return try decode(o.child, value, vm, temp);
        },
        else => unreachable,
    }
}

fn encode(comptime T: type, value: T, vm: *VM) !HostResult {
    switch (@typeInfo(T)) {
        .void => return .data(Value.new.nil()),
        .bool => return .data(Value.new.boolean(value)),
        .int, .float => return .data(Value.new.num(value)),
        .@"enum" => return .data(Value.new.num(@intFromEnum(value))),
        .optional => |o| {
            if (value) |present| return encode(o.child, present, vm);
            return .data(Value.new.nil());
        },
        .error_union => |e| {
            const payload = value catch |err| return .other(@errorName(err));
            return encode(e.payload, payload, vm);
        },
        .pointer => {
            if (@intFromPtr(value) == 0) return .data(Value.new.nil());
            // Use resource handles rather than packing native pointers into
            // Revo's 48-bit opaque value representation.
            return .data(try ext.resource(vm, @ptrFromInt(@intFromPtr(value))));
        },
        else => unreachable,
    }
}

fn Adapter(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    return struct {
        pub const tags: [info.param_types.len]ext.ParamType = blk: {
            var out: [info.param_types.len]ext.ParamType = undefined;
            for (info.param_types, 0..) |param, i| out[i] = paramType(param.?);
            break :blk out;
        };

        fn argsTuple() type {
            var types: [info.param_types.len]type = undefined;
            for (info.param_types, 0..) |param, i| types[i] = param.?;
            return @Tuple(&types);
        }

        pub fn call(args: []const Value, vm: *VM) anyerror!HostResult {
            if (args.len != info.param_types.len)
                return .errArity(args.len, info.param_types.len);

            var strings: [ext.max_params]?[:0]u8 = @splat(null);
            defer for (strings) |item| {
                if (item) |buf| vm.runtime.alloc.free(buf);
            };

            var native: argsTuple() = undefined;
            inline for (info.param_types, 0..) |param, i| {
                native[i] = decode(param.?, args[i], vm, &strings[i]) catch |err|
                    return .other(@errorName(err));
            }
            const result = @call(.auto, f, native);
            return encode(@TypeOf(result), result, vm);
        }
    };
}

/// Reflect the complete public namespace at compile time. Every compatible
/// Zig function is exported automatically under its existing name.
/// Unsupported signatures are omitted rather than producing unsafe calls.
pub fn bindingsFor(comptime Namespace: type) [count(Namespace) + 1]revo.HostBinding {
    var out: [count(Namespace) + 1]revo.HostBinding = undefined;
    var i: usize = 0;
    inline for (@typeInfo(Namespace).@"struct".decl_names) |name| {
        const f = @field(Namespace, name);
        if (comptime supportedFn(@TypeOf(f))) {
            const Bridge = Adapter(f);
            const terminated = name ++ "\x00";
            out[i] = ext.binding(terminated[0..name.len :0], ext.define(&Bridge.tags, Bridge.call));
            i += 1;
        }
    }
    out[i] = std.mem.zeroes(revo.HostBinding);
    return out;
}

test "functions discovered without declaration lists" {
    const Fixture = struct {
        pub fn sum(a: i32, b: i32) i32 { return a + b; }
        pub fn ready() bool { return true; }
        pub fn incompatible(_: []const u8) void {}
    };
    const bound = comptime bindingsFor(Fixture);
    try std.testing.expectEqual(@as(usize, 3), bound.len);
    try std.testing.expectEqualStrings("sum", std.mem.span(bound[0].name));
    try std.testing.expectEqualStrings("ready", std.mem.span(bound[1].name));
}
