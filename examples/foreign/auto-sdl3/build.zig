const std = @import("std");

// One project build, no per-function binding definitions.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const revo_dep = b.dependency("revo", .{ .target = target, .optimize = optimize });
    const sdl_dep = b.dependency("sdl3", .{ .target = target, .optimize = optimize });

    // Generated source is intentionally not checked in or maintained.
    const generated = b.addWriteFiles();
    const bindings = generated.add("sdl3_revo.zig",
        \\const revo = @import("revo");
        \\const sdl = @import("sdl3");
        \\pub export const revo_native_bindings_ex = revo.extension.autoCBindings(sdl.raw, "SDL_");
    );

    const library = b.addLibrary(.{
        .name = "sdl3_revo",
        .root_module = b.createModule(.{
            .root_source_file = bindings,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "revo", .module = revo_dep.module("revo") },
                .{ .name = "sdl3", .module = sdl_dep.module("sdl3") },
            },
        }),
        .linkage = .dynamic,
    });

    // sdl3-zig supplies the actual SDL3 implementation.
    b.getInstallStep().dependOn(&b.addInstallArtifact(library, .{}).step);
}
