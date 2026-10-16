//! Stable C ABI shared by Revo and automatically generated native extensions.
//! Only C-callable functions and nan-boxed Value cross the dylib boundary.
//! No *VM fields, allocators, tables or std container layouts are shared.
const Value = @import("vm").memory.Value;

pub const Api = extern struct {
    table_create: *const fn (*anyopaque) callconv(.c) Value,
    table_alen: *const fn (*anyopaque, Value) callconv(.c) u64,
    table_get_idx: *const fn (*anyopaque, Value, u64, *Value) callconv(.c) bool,
    table_push: *const fn (*anyopaque, Value, Value) callconv(.c) bool,
    table_get_name: *const fn (*anyopaque, Value, ?[*]const u8, usize, *Value) callconv(.c) bool,
    table_set_name: *const fn (*anyopaque, Value, ?[*]const u8, usize, Value) callconv(.c) bool,
    intern: *const fn (*anyopaque, ?[*]const u8, usize) callconv(.c) u64,
    string_data: *const fn (*anyopaque, u64) callconv(.c) ?[*]const u8,
    string_length: *const fn (*anyopaque, u64) callconv(.c) usize,
    resource_new: *const fn (*anyopaque, ?*anyopaque) callconv(.c) Value,
    resource_ptr: *const fn (*anyopaque, Value) callconv(.c) ?*anyopaque,
    error_other: *const fn (*anyopaque, [*:0]const u8) callconv(.c) c_int,
    error_arity: *const fn (*anyopaque, u64, u64) callconv(.c) c_int,
    ok_result: *const fn (*anyopaque, Value) callconv(.c) Value,
    err_result: *const fn (*anyopaque, Value) callconv(.c) Value,
};
