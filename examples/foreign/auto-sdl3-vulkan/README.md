# SDL3 + Snektron/vulkan-zig, no hand-authored Vulkan API shim

The example has `build.zig`, `build.zig.zon`, `Makefile`, `main.rv`,
`smoke.rv`, and this README; there is no handwritten Zig API shim. The Zig build imports both libraries and **generates** the two Revo
native modules:

- `sdl_revo.so` reflects SDL3 extern functions referenced in `main.rv` or `smoke.rv`
- `vulkan_revo.so` reflects supported functions in the `vulkan-zig` root namespace

No individual API function declarations or `vulkan.zig` wrapper are written.
The generic bindings use Revo's host-owned C ABI to marshal structs, arrays,
strings and native resources safely across the dynamic-library boundary.
`smoke.rv` verifies a real Vulkan Zig function returning a struct.

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

On macOS, a Vulkan-capable SDL3 window requires a Vulkan loader **and**
a working driver/ICD such as MoltenVK. Install them with:

```sh
brew install vulkan-tools
vulkaninfo --summary
```

The `make` / `make run` target selects Homebrew's Vulkan loader through
the `SDL_VULKAN_LIBRARY` hint when available, without hardcoded paths.
The example now calls `SDL_Vulkan_LoadLibrary` before `SDL_CreateWindow`
and prints the original `SDL_GetError()` message on failure. The native
binder automatically converts borrowed `const char *` return values into
Revo-owned strings (also covered by the `SDL_GetPlatform()` smoke test).

To run `main.rv` directly with the Homebrew loader:

```sh
SDL_VULKAN_LIBRARY="$(brew --prefix vulkan-loader)/lib/libvulkan.1.dylib" \
  ~/.local/bin/revo main.rv
```

A valid loader alone does not prove an installed Vulkan driver; check
`vulkaninfo --summary` if SDL reports a driver/ICD failure.

## Zig 0.17 compatibility

Snektron's `zig-0.17-compat` branch currently still contains a pre-0.17
`b.standardOptimizeOption(.{}) orelse .debug` call. `make deps` applies a
single build-system compatibility substitution to the locally fetched copy of
that dependency. It does not edit Vulkan API declarations, generate shims or
change any repository source code; `make compile` invokes `deps` first.

The Revo example intentionally avoids nested `else` blocks because the
older interpreter parser rejected that form in this example.
