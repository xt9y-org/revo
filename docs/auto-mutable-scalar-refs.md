# Automatic C scalar input/output references

The Revo Zig extension auto-binding adapter accepts an explicit writable Revo
table for supported scalar pointer arguments. It is generic: **no raygui
function-by-function adapters are required**.

## Usage with raygui

For translated raygui C declarations exposed using
`revo.extension.autoCBindings(raygui, "Gui")`:

```revo
const rl = import "./raylib_revo.so"

const editor = {
    shape = {value = 0.5},
    enabled = {value = :true},
    selected = {value = 0}
}

# Inside beginDrawing/endDrawing, after rendering the scene:
rl.GuiSlider(
    {x=100, y=80, width=200, height=24},
    "Shape", "", editor.shape, 0.0, 2.0
)
rl.GuiCheckBox(
    {x=100, y=120, width=24, height=24},
    "Enabled", editor.enabled
)

# The native functions change the shared reference tables.
print(editor.shape.value, editor.enabled.value)
```

Unlike value-returning convenience wrappers, the uppercase C-style
`GuiSlider` and `GuiCheckBox` **return their C status integer**. The
data updated by their pointer arguments lives in `ref.value`.

Supported automatically: writable one-element `*T` and `[*c]T` pointers,
where `T` is `bool`, float or integer at least 16 bits wide. The adapter:

1. Detects a Revo table argument and requires its `value` field.
2. Decodes that field to the native scalar type with normal validation.
3. Creates call-local, appropriately aligned native storage and passes its pointer.
4. Calls the C function.
5. Writes the updated scalar into the **same Revo table** before returning.
6. Preserves normal C return values and existing opaque/native pointer handles.

The table must be passed as a whole. Passing `ref.value` supplies a number,
not a mutable reference. A missing or wrong-typed `value` is an error.

**Safety boundary:** A C pointer type does not describe whether its callee
expects one element, a buffer or an array. Use `{value = ...}` **only for
documented scalar input/output parameters**. Arrays and character buffers
must use their own appropriate bindings/resource handles. The adapter excludes
8-bit integer and mutable string pointers from this shorthand, but other array
pointer types could still be mistaken for scalars by the caller. Invalid
signatures can corrupt memory. This is an explicit opt-in, not universal
automatic ownership inference.

## Revo repository: test without merging

Check out `feature/auto-mutable-scalar-refs` locally and run with Zig 0.17:

```sh
git fetch origin
git switch feature/auto-mutable-scalar-refs
zig build --fetch
zig build check
zig build test
```

This is a change to `src/auto_bindings.zig`; the shared native extension C
ABI is unchanged. Existing Revo executables can use rebuilt extensions if
they have the same auto-binding bridge ABI.

## Consumer: update raylib.rv later

**Do not assume updating the Revo executable updates the dependency used
to compile `raylib_revo.so`.** The extension itself must be rebuilt using the
updated source dependency.

After you decide to use this feature, in your `raylib.rv` checkout:

1. Change `Makefile`'s hard-coded `zig fetch --save=revo` revision from
   `ec6df43448380924ee4a79c00b3217e2df42165f` to the desired Revo
   commit (the tested feature-branch head or a later merged commit).
2. Run `zig fetch --save=revo 'git+https://github.com/xt9y-org/revo.git#<SHA>'`
   to update `build.zig.zon` with the matching Zig package hash.
3. Run `make compile` to rebuild `raylib_revo.so`.
4. Run your Revo raygui scene and test both the value writeback and the GUI
   interaction. Verify a regular non-pointer call such as `GuiButton` still
   works.

If the consumer has a separate locally installed Revo CLI and you want that
interpreter itself updated, build Revo with `zig build` and copy the
resulting `zig-out/bin/revo` to your preferred installation location.

No change to `raylib.rv/main` is required until you choose to adopt the
new Revo dependency. Do not merge this development branch without local
Zig and GUI runtime tests.
