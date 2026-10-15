# Revo + SDL3 + Snektron/vulkan-zig

Windowing is provided by SDL3; Vulkan API types, loader and dispatch
are provided by [Snektron/vulkan-zig](https://github.com/Snektron/vulkan-zig) (pinned to the \`zig-0.17-compat\` branch).
This smoke test initializes SDL video, creates a Vulkan window, loads Vulkan,
creates an instance with SDL's required extensions, and creates a Vulkan
surface. It then runs an event loop and destroys the surface, instance and window.

```sh
make deps
make compile REVO=../../../zig-out/bin/revo
make REVO=../../../zig-out/bin/revo
```

On macOS you must install a Vulkan loader and ICD (for example the Vulkan SDK
with MoltenVK). Metal support alone does not provide a Vulkan implementation.

Snektron/vulkan-zig exposes *dispatch table methods* that require an instance
and native Vulkan loader. The small `vulkan.zig` is application initialization
code, not a hand-maintained binding declaration list. Revo calls its application
operations, registered automatically by `autoBindings(API)`.

This example does NOT render a triangle or set up a graphics device/swapchain.
