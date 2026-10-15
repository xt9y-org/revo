//! Compile-time Zig namespace to Revo host-call adapters.
//! Reflect public function declarations; no per-function signature lists.
//! Value marshalling: bool, numeric/enum, arrays, slices, structs, tagged
//! unions, optionals and error unions. Native pointers remain opaque handles.
//! Callbacks/comptime-specialized and allocator-dependent APIs need an
//! explicit lifetime/specialization contract and are not auto-exported.
const std = @import("std");
const revo = @import("root.zig");
const ext = @import("extension.zig");

const Value = ext.Value;
const VM = ext.VM;
const HostResult = ext.HostResult;
const Allocator = std.mem.Allocator;

fn isCString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == u8 and p.is_const and (p.size == .c or (p.size == .many and p.sentinel_ptr != null)),
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
        .array => |a| a.len <= 4096 and supported(a.child, is_return),
        .pointer => |p| switch (p.size) {
            .slice => supported(p.child, is_return),
            // For an input C string we marshal from a Revo string, otherwise
            // pointers are handles. Returned pointers must remain valid.
            .one, .many, .c => @typeInfo(p.child) != .@"fn",
        },
        .optional => |o| supported(o.child, is_return),
        .@"struct" => |s| blk: {
            if (s.layout == .@"packed") break :blk false;
            for (s.fields) |f| {
                if (f.is_comptime or !supported(f.type, is_return)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) break :blk false;
            for (u.fields) |f| {
                if (!supported(f.type, is_return)) break :blk false;
            }
            break :blk true;
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
        .@"struct", .array, .@"union" => .table,
        .pointer => |p| if (p.size == .slice) .any else .any,
        else => .any,
    };
}

fn isNil(v: Value) bool {
    return v.asAtom() == revo.CoreAtoms.atomId(.nil);
}

fn number(comptime T: type, v: Value) !T {
    return ext.numToInt(T, v.asNumOpt() orelse return error.ExpectedNumber) orelse return error.IntegerOutOfRange;
}

fn decode(comptime T: type, v: Value, vm: *VM, alloc: Allocator) anyerror!T {
    switch (@typeInfo(T)) {
        .bool => {
            const a = v.asAtom() orelse return error.ExpectedBoolean;
            if (a == revo.CoreAtoms.atomId(.true)) return true;
            if (a == revo.CoreAtoms.atomId(.false)) return false;
            return error.ExpectedBoolean;
        },
        .int => return try number(T, v),
        .float => return @floatCast(v.asNumOpt() orelse return error.ExpectedNumber),
        .@"enum" => |e| return @enumFromInt(try number(e.tag_type, v)),
        .array => |a| {
            const id = v.asTable() orelse return error.ExpectedTable;
            const table = try vm.tables.get(id);
            if (table.array.items.len != a.len) return error.ArrayLengthMismatch;
            var out: T = undefined;
            for (0..a.len) |i|
                out[i] = try decode(a.child, table.array.items[i], vm, alloc);
            return out;
        },
        .pointer => |p| {
            if (comptime isCString(T)) {
                const sid = v.asString() orelse return error.ExpectedString;
                const copied = try alloc.dupeZ(u8, vm.stringValue(sid));
                return @ptrCast(copied.ptr);
            }
            if (p.size == .slice) {
                if (p.child == u8 and v.asString() != null) {
                    const source = vm.stringValue(v.asString().?);
                    if (p.sentinel_ptr != null) {
                        const copied = try alloc.dupeZ(u8, source);
                        return copied;
                    }
                    return try alloc.dupe(u8, source);
                }
                const id = v.asTable() orelse return error.ExpectedTable;
                const table = try vm.tables.get(id);
                const n = table.array.items.len;
                if (p.sentinel_ptr != null) return error.SentinelSliceRequiresString;
                const out = try alloc.alloc(p.child, n);
                for (0..n) |i| out[i] = try decode(p.child, table.array.items[i], vm, alloc);
                return out;
            }
            if (isNil(v)) {
                if (p.size == .c) return @ptrFromInt(0);
                return error.NullPointer;
            }
            const pointer = ext.resourcePtr(vm, v) orelse v.asOpaque() orelse return error.ExpectedPointer;
            return @ptrFromInt(@intFromPtr(pointer));
        },
        .optional => |o| {
            if (isNil(v)) return null;
            return try decode(o.child, v, vm, alloc);
        },
        .@"struct" => |s| {
            const id = v.asTable() orelse return error.ExpectedTable;
            var out: T = undefined;
            inline for (s.fields) |field| {
                const item = vm.getField(Value.new.table(id), field.name) orelse return error.MissingStructField;
                @field(out, field.name) = try decode(field.type, item, vm, alloc);
            }
            return out;
        },
        .@"union" => |u| {
            const id = v.asTable() orelse return error.ExpectedTable;
            const tag_value = vm.getField(Value.new.table(id), "tag") orelse return error.MissingUnionTag;
            const sid = tag_value.asString() orelse return error.ExpectedString;
            const name = vm.stringValue(sid);
            inline for (u.fields) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    if (field.type == void) return @unionInit(T, field.name, {});
                    const data = vm.getField(Value.new.table(id), "value") orelse return error.MissingUnionValue;
                    return @unionInit(T, field.name, try decode(field.type, data, vm, alloc));
                }
            }
            return error.UnknownUnionTag;
        },
        else => unreachable,
    }
}

fn encode(comptime T: type, v: T, vm: *VM) anyerror!Value {
    switch (@typeInfo(T)) {
        .void => return Value.new.nil(),
        .bool => return Value.new.boolean(v),
        .int => {
            const f: f64 = @floatFromInt(v);
            // Revo uses f64 numbers. Do not silently round a 64-bit integer.
            if ((ext.numToInt(T, f) orelse return error.LossyInteger) != v) return error.LossyInteger;
            return Value.new.num(f);
        },
        .float => return Value.new.num(v),
        .@"enum" => return encode(@TypeOf(@intFromEnum(v)), @intFromEnum(v), vm),
        .array => |a| {
            const id = try vm.tables.create();
            const table = try vm.tables.get(id);
            for (0..a.len) |i| try table.array.append(vm.runtime.alloc, try encode(a.child, v[i], vm));
            return Value.new.table(id);
        },
        .pointer => |p| {
            if (p.size == .slice) {
                // Byte slices are copied into Revo-owned strings.
                if (p.child == u8) return try vm.ownValueStringNoDedup(try vm.runtime.alloc.dupe(u8, v));
                const id = try vm.tables.create();
                for (v) |item| {
                    const table = try vm.tables.get(id);
                    try table.array.append(vm.runtime.alloc, try encode(p.child, item, vm));
                }
                return Value.new.table(id);
            }
            if (@intFromPtr(v) == 0) return Value.new.nil();
            return try ext.resource(vm, @ptrFromInt(@intFromPtr(v)));
        },
        .optional => |o| {
            if (v) |payload| return encode(o.child, payload, vm);
            return Value.new.nil();
        },
        .@"struct" => |s| {
            const id = try vm.tables.create();
            inline for (s.fields) |field|
                try vm.putField(id, field.name, try encode(field.type, @field(v, field.name), vm));
            return Value.new.table(id);
        },
        .@"union" => {
            const id = try vm.tables.create();
            switch (v) {
                inline else => |payload, tag| {
                    try vm.putField(id, "tag", try vm.ownValueStringNoDedup(try vm.runtime.alloc.dupe(u8, @tagName(tag))));
                    if (@TypeOf(payload) != void)
                        try vm.putField(id, "value", try encode(@TypeOf(payload), payload, vm));
                },
            }
            return Value.new.table(id);
        },
        .error_union => |e| {
            const payload = v catch |err| {
                return try vm.resultTable(.err, try vm.ownValueStringNoDedup(try vm.runtime.alloc.dupe(u8, @errorName(err))));
            };
            return encode(e.payload, payload, vm);
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
        fn Args() type {
            var types: [info.param_types.len]type = undefined;
            for (info.param_types, 0..) |param, i| types[i] = param.?;
            return @Tuple(&types);
        }
        pub fn call(args: []const Value, vm: *VM) anyerror!HostResult {
            if (args.len != info.param_types.len)
                return .errArity(args.len, info.param_types.len);

            var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
            defer arena.deinit();
            var native: Args() = undefined;
            inline for (info.param_types, 0..) |p, i| {
                native[i] = decode(p.?, args[i], vm, arena.allocator()) catch |err|
                    return .other(@errorName(err));
            }
            const result = @call(.auto, f, native);
            const value = try encode(@TypeOf(result), result, vm);
            return .data(value);
        }
    };
}

/// Export every public Zig function whose signature can be represented.
/// Unsupported functions are omitted; no unsafe coercion is attempted.
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

test "automatically exports structural APIs without manual declarations" {
    const Fixture = struct {
        pub fn add(a: i32, b: i32) i32 { return a + b; }
        pub fn transform(s: struct { x: f32, y: f32 }) struct { x: f32, y: f32 } {
            return .{ .x = s.x * 2, .y = s.y * 3 };
        }
        pub fn sum(items: []const i32) i32 {
            var out: i32 = 0;
            for (items) |item| out += item;
            return out;
        }
        pub fn impossible(comptime _: type) void {}
    };
    const bound = comptime bindingsFor(Fixture);
    try std.testing.expectEqual(@as(usize, 4), bound.len);
    try std.testing.expectEqualStrings("add", std.mem.span(bound[0].name));
    try std.testing.expectEqualStrings("transform", std.mem.span(bound[1].name));
    try std.testing.expectEqualStrings("sum", std.mem.span(bound[2].name));
}
