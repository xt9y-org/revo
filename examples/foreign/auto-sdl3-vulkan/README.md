# SDL3 + Snektron/vulkan-zig, no hand-authored Vulkan API shim

Only `build.zig`, `build.zig.zon`, `Makefile`, and `main.rv` are
present. The Zig build imports both libraries and **generates** the two Revo
native modules:

- `sdl_revo.so` reflects the SDL3 raw function namespace
- `vulkan_revo.so` reflects the generated `vulkan-zig` root namespace

No individual API function declarations or `vulkan.zig` wrapper are written.

```sh
make deps
make compile REVO=../../../zig-out/bin/revo
make REVO=../../../zig-out/bin/revo
```

This smoke test opens an SDL3 Vulkan-flagged window and initializes the
system Vulkan loader. **It does not yet create a Vulkan instance, surface,
device or swapchain.** Snektron/vulkan-zig's actual commands are dynamically
loaded through dispatch tables, not global Zig functions. Revo's current
automatic binder discovers ordinary public functions but cannot yet construct
and call those runtime dispatch table methods, compile Zig generic loader
functions, or marshal arbitrary Vulkan out-parameters. The `vk` import is
present, but complete Vulkan dispatch requires extending the *generic
interoperability infrastructure*, not adding application-specific wrappers.

On macOS Vulkan requires MoltenVK and a compatible Vulkan loader/ICD.
