const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const revo = b.dependency("revo", .{ .target = target, .optimize = optimize });
    const sdl = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .vulkan = true,
    });
    const headers = b.dependency("vulkan_headers", .{});
    const vk = b.dependency("vulkan_zig", .{
        .registry = headers.path("registry/vk.xml"),
    });

    const lib = b.addLibrary(.{
        .name = "vulkan_revo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vulkan.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "revo", .module = revo.module("revo") },
                .{ .name = "sdl3", .module = sdl.module("sdl3") },
                .{ .name = "vulkan", .module = vk.module("vulkan-zig") },
            },
        }),
        .linkage = .dynamic,
    });
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);
}
