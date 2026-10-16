const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const revo_dep = b.dependency("revo", .{ .target = target, .optimize = optimize });
    const raylib_dep = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });
    // raylib-zig registers its module internally, rather than exposing it
    // through dependency.module(). Import the public source directly.
    const raylib_module = b.createModule(.{
        .root_source_file = raylib_dep.path("lib/raylib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const src = b.addWriteFiles().add("raylib_revo.zig",
        \\const revo = @import("revo");
        \\const raylib = @import("raylib");
        \\pub export const revo_native_bindings_ex = revo.extension.autoBindings(raylib);
    );
    const lib = b.addLibrary(.{
        .name = "raylib_revo",
        .root_module = b.createModule(.{
            .root_source_file = src,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "revo", .module = revo_dep.module("revo") },
                .{ .name = "raylib", .module = raylib_module },
            },
        }),
        .linkage = .dynamic,
    });
    lib.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);
}
