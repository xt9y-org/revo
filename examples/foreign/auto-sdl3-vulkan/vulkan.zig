//! SDL3 window and Vulkan instance/surface via Snektron/vulkan-zig.
//! Only application operations are exposed, without binding declarations.
const std = @import("std");
const builtin = @import("builtin");
const revo = @import("revo");
const sdl = @import("sdl3");
const vk = @import("vulkan");

const Context = struct {
    window: sdl.Window,
    instance: vk.Instance,
    dispatcher: vk.InstanceWrapper,
    surface: sdl.vulkan.Surface,
};

var context: ?Context = null;

fn start(width: i32, height: i32) !void {
    try sdl.init(.{ .video = true });
    errdefer sdl.quit();

    const window = try sdl.Window.init("Revo / SDL3 / Vulkan", width, height, .{
        .vulkan = true,
        .resizable = true,
    });
    errdefer window.deinit();

    const proc: vk.PfnGetInstanceProcAddr =
        @ptrCast(@alignCast(try sdl.vulkan.getInstanceProcAddr()));
    const base = vk.BaseWrapper.load(proc);

    const requested = try sdl.vulkan.instanceExtensions();
    const on_mac = builtin.os.tag == .macos;
    const alloc = std.heap.page_allocator;
    const names = try alloc.alloc([*:0]const u8, requested.len + (if (on_mac) @as(usize, 2) else 0));
    defer alloc.free(names);
    @memcpy(names[0..requested.len], requested);
    if (on_mac) {
        names[requested.len] = vk.instance_extensions.khr_portability_enumeration.name;
        names[requested.len + 1] = vk.instance_extensions.khr_get_physical_device_properties_2.name;
    }

    const instance = try base.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "Revo Vulkan",
            .api_version = vk.API_VERSION_1_0.toU32(),
        },
        .enabled_extension_count = @intCast(names.len),
        .pp_enabled_extension_names = names.ptr,
        .flags = .{ .enumerate_portability_khr = on_mac },
    }, null);
    const dispatcher = vk.InstanceWrapper.load(instance, base.dispatch.vkGetInstanceProcAddr.?);
    errdefer dispatcher.destroyInstance(instance, null);

    const raw_instance: sdl.vulkan.Instance = @ptrFromInt(@intFromEnum(instance));
    const surface = try sdl.vulkan.createSurface(raw_instance, window, null);

    context = .{
        .window = window,
        .instance = instance,
        .dispatcher = dispatcher,
        .surface = surface,
    };
}

const API = struct {
    pub fn open(width: i32, height: i32) bool {
        if (context != null) return true;
        start(width, height) catch |err| {
            std.log.err("Vulkan initialization: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    pub fn poll() bool {
        if (context == null) return false;
        while (sdl.events.poll()) |event| switch (event) {
            .quit => return false,
            .window => |e| switch (e.kind) {
                .close_requested => return false,
                else => {},
            },
            .key_down => |e| {
                if (e.key == .escape) return false;
            },
            else => {},
        };
        sdl.raw.SDL_Delay(16);
        return true;
    }

    pub fn close() void {
        const ctx = context orelse return;
        context = null;
        const raw_instance: sdl.vulkan.Instance = @ptrFromInt(@intFromEnum(ctx.instance));
        sdl.vulkan.destroySurface(raw_instance, ctx.surface, null);
        ctx.dispatcher.destroyInstance(ctx.instance, null);
        ctx.window.deinit();
        sdl.quit();
    }
};

pub export const revo_native_bindings_ex = revo.extension.autoBindings(API);
