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
const BridgeApi = @import("auto_binding_abi.zig").Api;

/// A pointer to the actual host's stable C API. Set by capi.loadC after
/// dlopen, before any generated adapter executes. This is an ABI slot only.
pub export var revo_auto_api: ?*const BridgeApi = null;

fn bridge() !*const BridgeApi {
    return revo_auto_api orelse error.NativeBridgeUnavailable;
}
fn opaqueVM(vm: *VM) *anyopaque {
    return @ptrCast(vm);
}
fn tableNew(vm: *VM) !Value {
    const value = (try bridge()).table_create(opaqueVM(vm));
    if (!value.isTable()) return error.TableAllocationFailed;
    return value;
}
fn tableLength(vm: *VM, v: Value) !usize {
    if (!v.isTable()) return error.ExpectedTable;
    return @intCast((try bridge()).table_alen(opaqueVM(vm), v));
}
fn tableItem(vm: *VM, v: Value, index: usize) !Value {
    var result: Value = undefined;
    if (!(try bridge()).table_get_idx(opaqueVM(vm), v, @intCast(index), &result))
        return error.TableIndexMissing;
    return result;
}
fn tablePush(vm: *VM, v: Value, item: Value) !void {
    if (!(try bridge()).table_push(opaqueVM(vm), v, item))
        return error.TableWriteFailed;
}
fn tableField(vm: *VM, v: Value, key: []const u8) !Value {
    var result: Value = undefined;
    if (!(try bridge()).table_get_name(opaqueVM(vm), v, key.ptr, key.len, &result))
        return error.MissingStructField;
    return result;
}
fn tablePut(vm: *VM, v: Value, key: []const u8, item: Value) !void {
    if (!(try bridge()).table_set_name(opaqueVM(vm), v, key.ptr, key.len, item))
        return error.TableWriteFailed;
}
fn stringBytes(vm: *VM, id: usize) ![]const u8 {
    const api = try bridge();
    const ptr = api.string_data(opaqueVM(vm), @intCast(id)) orelse return error.InvalidString;
    return ptr[0..api.string_length(opaqueVM(vm), @intCast(id))];
}
fn valueString(vm: *VM, bytes: []const u8) !Value {
    const id = (try bridge()).intern(opaqueVM(vm), bytes.ptr, bytes.len);
    if (id == 0) return error.StringAllocationFailed;
    return Value.new.str(@intCast(id));
}
fn pointerResource(vm: *VM, ptr: ?*anyopaque) !Value {
    const value = (try bridge()).resource_new(opaqueVM(vm), ptr);
    if (!value.isResource()) return error.ResourceAllocationFailed;
    return value;
}
fn getResource(vm: *VM, val: Value) !?*anyopaque {
    return (try bridge()).resource_ptr(opaqueVM(vm), val);
}


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
        // SDL's C functions use SDL_UpperCamelCase. Compiler macro helpers
        // such as SDL_copyp use a lowercase initial letter and may expand to
        // @compileError during translate-c. Reject these before @field.
        if (name.len <= prefix.len) return false;
        const initial = name[prefix.len];
        if (initial < 'A' or initial > 'Z') return false;
        // SCREAMING_SNAKE_CASE constants cannot be callable functions.
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
            if (try tableLength(vm, v) != a.len) return error.ArrayLengthMismatch;
            var out: T = undefined;
            for (0..a.len) |i|
                out[i] = try decode(a.child, try tableItem(vm, v, i), vm, alloc);
            return out;
        },
        .pointer => |p| {
            if (comptime isCString(T)) {
                if (isNil(v) and p.size == .c) return @ptrFromInt(0);
                const sid = v.asString() orelse return error.ExpectedString;
                const copied = try alloc.dupeSentinel(u8, try stringBytes(vm, sid), 0);
                return @ptrCast(copied.ptr);
            }
            if (p.size == .slice) {
                if (p.child == u8) {
                    if (v.asString()) |sid| {
                        const src = try stringBytes(vm, sid);
                        if (p.sentinel_ptr != null) return try alloc.dupeSentinel(u8, src, 0);
                        return try alloc.dupe(u8, src);
                    }
                }
                if (p.sentinel_ptr != null) return error.SentinelSliceRequiresString;
                const n = try tableLength(vm, v);
                const out = try alloc.alloc(p.child, n);
                for (0..n) |i| out[i] = try decode(p.child, try tableItem(vm, v, i), vm, alloc);
                return out;
            }
            if (isNil(v)) {
                if (p.size == .c) return @ptrFromInt(0);
                return error.NullPointer;
            }
            const ptr = try getResource(vm, v) orelse v.asOpaque() orelse return error.ExpectedPointer;
            return @ptrFromInt(@intFromPtr(ptr));
        },
        .optional => |o| {
            if (isNil(v)) return null;
            return try decode(o.child, v, vm, alloc);
        },
        .@"struct" => |s| {
            if (!v.isTable()) return error.ExpectedTable;
            var out: T = undefined;
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                @field(out, field_name) = try decode(field_type, try tableField(vm, v, field_name), vm, alloc);
            }
            return out;
        },
        .@"union" => |u| {
            if (!v.isTable()) return error.ExpectedTable;
            const tag_value = try tableField(vm, v, "tag");
            const sid = tag_value.asString() orelse return error.ExpectedString;
            const name = try stringBytes(vm, sid);
            inline for (u.field_names, u.field_types) |field_name, field_type| {
                if (std.mem.eql(u8, name, field_name)) {
                    if (field_type == void) return @unionInit(T, field_name, {});
                    return @unionInit(T, field_name, try decode(field_type, try tableField(vm, v, "value"), vm, alloc));
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
            if ((ext.numToInt(T, f) orelse return error.LossyInteger) != v) return error.LossyInteger;
            return Value.new.num(f);
        },
        .float => return Value.new.num(v),
        .@"enum" => return encode(@TypeOf(@intFromEnum(v)), @intFromEnum(v), vm),
        .array => |a| {
            const t = try tableNew(vm);
            for (0..a.len) |i| try tablePush(vm, t, try encode(a.child, v[i], vm));
            return t;
        },
        .pointer => |p| {
            // Returned const C character pointers conventionally represent
            // borrowed, NUL-terminated strings (e.g. SDL_GetError()).
            // Copy immediately into host-owned Revo storage: never pass the
            // thread-local library buffer to Revo as a raw resource handle.
            if (comptime isCString(T)) {
                if (@intFromPtr(v) == 0) return Value.new.nil();
                const text_ptr: [*:0]const u8 = @ptrCast(v);
                return try valueString(vm, std.mem.span(text_ptr));
            }
            if (p.size == .slice) {
                if (p.child == u8) return try valueString(vm, v);
                const t = try tableNew(vm);
                for (v) |item| try tablePush(vm, t, try encode(p.child, item, vm));
                return t;
            }
            if (@intFromPtr(v) == 0) return Value.new.nil();
            return try pointerResource(vm, @ptrFromInt(@intFromPtr(v)));
        },
        .optional => |o| {
            if (v) |payload| return encode(o.child, payload, vm);
            return Value.new.nil();
        },
        .@"struct" => |s| {
            const t = try tableNew(vm);
            inline for (s.field_names, s.field_types) |field_name, field_type|
                try tablePut(vm, t, field_name, try encode(field_type, @field(v, field_name), vm));
            return t;
        },
        .@"union" => {
            const t = try tableNew(vm);
            switch (v) {
                inline else => |payload, tag| {
                    try tablePut(vm, t, "tag", try valueString(vm, @tagName(tag)));
                    if (@TypeOf(payload) != void)
                        try tablePut(vm, t, "value", try encode(@TypeOf(payload), payload, vm));
                },
            }
            return t;
        },
        .error_union => |e| {
            const payload = v catch |err| {
                const result = (try bridge()).err_result(opaqueVM(vm), try valueString(vm, @errorName(err)));
                if (isNil(result)) return error.ErrorResultAllocationFailed;
                return result;
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

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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

        // Dynamically loaded native modules must use the stable C ABI.
        // Passing a Zig []const Value and error-union HostResult directly
        // between separately compiled Mach-O binaries corrupts arguments.
        pub fn callC(vm_ptr: *anyopaque, argc: usize, argv: [*]const Value, out: *Value) callconv(.c) c_int {
            const vm: *VM = @ptrCast(@alignCast(vm_ptr));
            const api = revo_auto_api orelse return revo.callable.c_err_other;
            const result = call(argv[0..argc], vm) catch |err|
                return api.error_other(vm_ptr, @errorName(err));
            return switch (result) {
                .ok => |v| blk: {
                    out.* = v;
                    break :blk revo.callable.c_ok;
                },
                .err => |e| switch (e) {
                    .wrong_arity => |a| api.error_arity(vm_ptr, @intCast(a.got), @intCast(a.expected)),
                    .type_error => api.error_other(vm_ptr, "native binding type mismatch"),
                    .other => api.error_other(vm_ptr, "native binding conversion failed"),
                    else => api.error_other(vm_ptr, "native binding error"),
                },
            };
        }
    };
}

/// Export every public Zig function whose signature can be represented.
/// Unsupported functions are omitted; no unsafe coercion is attempted.
fn bindingsFiltered(comptime Namespace: type, comptime c_prefix: ?[]const u8) [count(Namespace, c_prefix) + 1]revo.callable.RevoBinding {
    @setEvalBranchQuota(2_000_000);
    var out: [count(Namespace, c_prefix) + 1]revo.callable.RevoBinding = undefined;
    var i: usize = 0;
    inline for (@typeInfo(Namespace).@"struct".decl_names) |name| {
        if (comptime !inspectName(name, c_prefix)) continue;
        // Reflect type first; never evaluate a runtime global at comptime.
        if (comptime supportedFn(@TypeOf(@field(Namespace, name)))) {
            const f = @field(Namespace, name);
            const Bridge = Adapter(f);
            const terminated = name ++ "\x00";
            out[i] = .{
                .name = terminated[0..name.len :0],
                .fn_ptr = @ptrCast(&Bridge.callC),
            };
            i += 1;
        }
    }
    out[i] = std.mem.zeroes(revo.callable.RevoBinding);
    return out;
}

/// Reflect a Zig namespace with no manual function registration.
pub fn bindingsFor(comptime Namespace: type) [count(Namespace, null) + 1]revo.callable.RevoBinding {
    return bindingsFiltered(Namespace, null);
}

/// Auto-bind the C functions of a translated package. For example "SDL_"
/// selects SDL_* functions but skips C macro placeholders without evaluating
/// their @compileError declarations. No per-function list is maintained.
pub fn cBindingsFor(comptime Namespace: type, comptime prefix: []const u8) [count(Namespace, prefix) + 1]revo.callable.RevoBinding {
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
