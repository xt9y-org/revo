# Revo + Raylib without per-function bindings

This example passes the complete raylib-zig namespace to
`revo.extension.autoBindings(raylib)`. It does not manually enumerate or wrap
raylib functions. Build and run with:

```sh
make deps
make compile REVO=../../../zig-out/bin/revo
make REVO=../../../zig-out/bin/revo
```

The generated extension exposes only signatures the bridge can safely
represent. For instance, functions taking enums, structs and strings have
corresponding Revo numeric, table and string inputs. Unsupported functions
are not exposed, rather than being imported unsafely. Zig 0.17 is required.

See `../raylib/` for Revo's existing manually wrapped raylib reference example.

The example uses the public `raylib-zig` API and automatically fetches
its matching native `raysan5/raylib` source revision. This avoids missing
symbols from a separately installed or older Raylib library. Run
`make compile` to fetch and build both parts without writing API declarations.
