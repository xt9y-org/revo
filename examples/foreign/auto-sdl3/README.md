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

## Limitations

This is **not** automatic support for every possible Zig type. A function is
automatically exported only if its signature uses booleans, numeric scalars,
enums, compatible pointers, optional pointers or a supported error-union return.
Read-only C-style byte pointers are marshalled as temporary NUL-terminated
Revo strings. Returned native pointers are boxed as Revo resources.

Functions using structs by value, slices, callback parameters, generic/comptime
arguments and other complex types are **skipped**, not wrapped incorrectly.
Native pointer resources do not carry SDL ownership semantics; call the proper
SDL destruction function. The raw SDL API includes many operations taking
pointers to caller-owned structs (e.g. `SDL_PollEvent`). Calling those requires
a separate generic memory/struct representation, which this example does not
provide.

Zig's build system is used only to compile the native package. The ordinary
Revo script contains no binding declarations. This extension resides in two
isolated fork files: `src/auto_bindings.zig` plus a one-line export from
`src/extension.zig` to reduce conflicts when merging upstream.
