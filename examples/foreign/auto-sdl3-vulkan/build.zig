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

    // Bind only actual SDL extern declarations from the translated C source,
    // not preprocessor macro placeholders that can fail Zig compilation.
    const raw = sdl.module("sdl3").import_table.get("sdl3_raw").?;
    const generate_sdl = b.addSystemCommand(&.{"python3"});
    generate_sdl.addFileArg(revo.path("src/auto_c_bindings.py"));
    generate_sdl.addFileArg(raw.root_source_file.?);
    const sdl_source = generate_sdl.addOutputFileArg("sdl_revo.zig");
    generate_sdl.addArgs(&.{ "sdl3", "SDL_" });
    generate_sdl.addFileArg(b.path("main.rv"));
    generate_sdl.addFileArg(b.path("smoke.rv"));

    // The Vulkan namespace comes directly from Snektron/vulkan-zig.
    // No separate handwritten vulkan.zig or per-function registration.
    const generated = b.addWriteFiles();
    const vk_source = generated.add("vulkan_revo.zig",
        \\const revo = @import("revo");
        \\const vk = @import("vulkan");
        \\pub export const revo_native_bindings_ex = revo.extension.autoBindings(vk);
    );
    const sources = .{ sdl_source, vk_source };

    const packages = .{
        .{ .name = "sdl_revo", .source = sources[0], .import_name = "sdl3", .module = sdl.module("sdl3") },
        .{ .name = "vulkan_revo", .source = sources[1], .import_name = "vulkan", .module = vk.module("vulkan-zig") },
    };

    inline for (packages) |pkg| {
        const library = b.addLibrary(.{
            .name = pkg.name,
            .root_module = b.createModule(.{
                .root_source_file = pkg.source,
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "revo", .module = revo.module("revo") },
                    .{ .name = pkg.import_name, .module = pkg.module },
                },
            }),
            .linkage = .dynamic,
        });
        b.getInstallStep().dependOn(&b.addInstallArtifact(library, .{}).step);
    }
}
