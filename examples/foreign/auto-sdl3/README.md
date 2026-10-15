# Revo + SDL3 — automatically generated Zig bindings

This example shows how to import an entire Zig namespace into Revo **without
listing, declaring or hand-writing wrappers for individual functions**.

`build.zig` imports [sdl3-zig](https://github.com/zmscode/sdl3-zig),
then generates a tiny `sdl3_revo.zig` module using
`revo.extension.autoBindings(sdl.raw)`. Revo's existing native extension loader
imports the generated dynamic library. Nothing is added to Revo's VM bytecode
or parser.

## Setup (Zig 0.17 / current Revo main)

From this directory:

```sh
make deps
make compile
make
```

`make deps` records the Zig package URL/hash in `build.zig.zon`.
`make compile` creates `sdl3_revo.so` (Mach-O on macOS) and checks `main.rv`.
`make` compiles and runs the Revo program. The window closes using the system
close button. The example intentionally uses only SDL's simple scalar/pointer API.

## Generic type coverage

The reflection generator automatically discovers native functions that use:

- Booleans, numbers, integer-backed enums and opaque native pointers
- Nested structs and fixed-size arrays (Revo named/indexed tables)
- Slices (Revo tables) and byte slices (Revo strings)
- Optionals and tagged unions (`{tag = "...", value = ...}`)
- Zig error-union return values, mapped to Revo error results

No per-function declarations or SDL-specific wrappers are maintained. The
source API is reflected at Zig compile time.

## Hard boundaries

This is **not a universal Zig interpreter or complete SDL3 importer**. Zig
comptime functions require compile-time arguments and cannot be instantiated
from an arbitrary Revo runtime call. Callbacks require an explicit ownership
and thread-execution policy. A Zig allocator cannot be conjured from Revo
without a memory/lifetime contract. Untagged C unions do not encode safely
without knowing which field is active. Packed structs, function pointers and
recursive types beyond the reflection safety limit are not automatically
exposed. Public constants/types and nested method namespaces are not yet
transferred to the Revo module table.

Raw pointers are preserved as opaque Revo resources rather than being
unsafely truncated into floating-point numbers. They do not automatically
manage the library's memory: call the documented native deinitializer.
The automatic marshalling of byte buffers and slices copies values and does
not expose an arena buffer beyond the native call.

An SDL3 window can use the scalar/pointer API (such as SDL_Init and
SDL_CreateWindow), but APIs like SDL_PollEvent that fill caller-owned
SDL_Event structures require a native out-parameter allocation and layout
model before they can be used directly.
