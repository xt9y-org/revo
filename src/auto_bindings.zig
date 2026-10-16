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
        .pointer => |p| p.child == u8 and p.attrs.@"const" and (p.size == .c or (p.size == .many and p.sentinel_ptr != null)),
        else => false,
    };
}

fn supported(comptime T: type, comptime is_return: bool) bool {
    return supportedDepth(T, is_return, 0);
}

fn supportedDepth(comptime T: type, comptime is_return: bool, comptime depth: u8) bool {
    if (depth > 12) return false;
    return switch (@typeInfo(T)) {
        .void => is_return or depth > 0,
        .bool => true,
        .int => |i| i.bits <= 64,
        .float => |f| f.bits <= 64,
        .@"enum" => |e| @typeInfo(e.tag_type).int.bits <= 64,
        .array => |a| a.len <= 4096 and supportedDepth(a.child, is_return, depth + 1),
        .pointer => |p| switch (p.size) {
            .slice => supportedDepth(p.child, is_return, depth + 1),
            // For an input C string we marshal from a Revo string, otherwise
            // pointers are handles. Returned pointers must remain valid.
            .one, .many, .c => @typeInfo(p.child) != .@"fn",
        },
        .optional => |o| supportedDepth(o.child, is_return, depth + 1),
        .@"struct" => |s| blk: {
            for (s.field_types, s.field_attrs) |field_type, attrs| {
                if (attrs.@"comptime" or !supportedDepth(field_type, is_return, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) break :blk false;
            for (u.field_types) |field_type| {
                if (!supportedDepth(field_type, is_return, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .error_union => |e| is_return and supportedDepth(e.payload, true, depth + 1),
        else => false,
    };
}

fn supportedFn(comptime T: type) bool {
    if (@typeInfo(T) != .@"fn") return false;
    const f = @typeInfo(T).@"fn";
    if (f.is_generic or f.attrs.varargs or f.param_types.len > ext.max_params) return false;
    if (f.return_type == null or !supported(f.return_type.?, true)) return false;
    for (f.param_types) |p| {
        if (p == null or !supported(p.?, false)) return false;
    }
    return true;
}

fn constantType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .bool, .int, .float, .@"enum" => true,
        else => false,
    };
}

fn Constant(comptime value: anytype) type {
    return struct {
        const types = [_]ext.ParamType{};
        pub fn call(args: []const Value, vm: *VM) anyerror!HostResult {
            if (args.len != 0) return .errArity(args.len, 0);
            return .data(try encode(@TypeOf(value), value, vm));
        }
    };
}

/// A translated C namespace also contains macros and typedefs. Some macro
/// placeholders expand to @compileError, so they must be filtered by name
/// before Zig attempts to evaluate their declarations.
fn inspectName(comptime name: []const u8, comptime c_prefix: ?[]const u8) bool {
    if (std.mem.startsWith(u8, name, "__")) return false;
    if (c_prefix) |prefix| {
        if (!std.mem.startsWith(u8, name, prefix)) return false;
        // C function names contain lowercase letters; SCREAMING_SNAKE_CASE
        // preprocessor macros do not. This avoids evaluating broken macros.
        for (name[prefix.len..]) |ch| {
            if (ch >= 'a' and ch <= 'z') return true;
        }
        return false;
    }
    return true;
}

fn count(comptime Namespace: type, comptime c_prefix: ?[]const u8) usize {
    @setEvalBranchQuota(2_000_000);
    var n: usize = 0;
    inline for (@typeInfo(Namespace).@"struct".decl_names) |name| {
        if (comptime !inspectName(name, c_prefix)) continue;
        // Do not evaluate imported global variables at comptime.
        // Some translated C namespaces expose runtime extern variables.
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
                if (isNil(v) and p.size == .c) return @ptrFromInt(0);
                const sid = v.asString() orelse return error.ExpectedString;
                const copied = try alloc.dupeSentinel(u8, vm.stringValue(sid), 0);
                return @ptrCast(copied.ptr);
            }
            if (p.size == .slice) {
                if (p.child == u8 and v.asString() != null) {
                    const source = vm.stringValue(v.asString().?);
                    if (p.sentinel_ptr != null) {
                        const copied = try alloc.dupeSentinel(u8, source, 0);
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
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                const item = vm.getField(Value.new.table(id), field_name) orelse return error.MissingStructField;
                @field(out, field_name) = try decode(field_type, item, vm, alloc);
            }
            return out;
        },
        .@"union" => |u| {
            const id = v.asTable() orelse return error.ExpectedTable;
            const tag_value = vm.getField(Value.new.table(id), "tag") orelse return error.MissingUnionTag;
            const sid = tag_value.asString() orelse return error.ExpectedString;
            const name = vm.stringValue(sid);
            inline for (u.field_names, u.field_types) |field_name, field_type| {
                if (std.mem.eql(u8, name, field_name)) {
                    if (field_type == void) return @unionInit(T, field_name, {});
                    const data = vm.getField(Value.new.table(id), "value") orelse return error.MissingUnionValue;
                    return @unionInit(T, field_name, try decode(field_type, data, vm, alloc));
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
        .comptime_int, .comptime_float => return Value.new.num(v),
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
            inline for (s.field_names, s.field_types) |field_name, field_type|
                try vm.putField(id, field_name, try encode(field_type, @field(v, field_name), vm));
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
fn bindingsFiltered(comptime Namespace: type, comptime c_prefix: ?[]const u8) [count(Namespace, c_prefix) + 1]revo.HostBinding {
    @setEvalBranchQuota(2_000_000);
    var out: [count(Namespace, c_prefix) + 1]revo.HostBinding = undefined;
    var i: usize = 0;
    inline for (@typeInfo(Namespace).@"struct".decl_names) |name| {
        if (comptime !inspectName(name, c_prefix)) continue;
        // Reflect type first; never evaluate a runtime global at comptime.
        if (comptime supportedFn(@TypeOf(@field(Namespace, name)))) {
            const f = @field(Namespace, name);
            const Bridge = Adapter(f);
            const terminated = name ++ "\x00";
            out[i] = ext.binding(terminated[0..name.len :0], ext.define(&Bridge.tags, Bridge.call));
            i += 1;
        }
    }
    out[i] = std.mem.zeroes(revo.HostBinding);
    return out;
}

/// Reflect a Zig namespace with no manual function registration.
pub fn bindingsFor(comptime Namespace: type) [count(Namespace, null) + 1]revo.HostBinding {
    return bindingsFiltered(Namespace, null);
}

/// Auto-bind the C functions of a translated package. For example "SDL_"
/// selects SDL_* functions but skips C macro placeholders without evaluating
/// their @compileError declarations. No per-function list is maintained.
pub fn cBindingsFor(comptime Namespace: type, comptime prefix: []const u8) [count(Namespace, prefix) + 1]revo.HostBinding {
    return bindingsFiltered(Namespace, prefix);
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
