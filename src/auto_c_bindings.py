#!/usr/bin/env python3
"""Generate a Revo binding namespace from translated C function declarations.

The Zig translate-c output includes macros that expand to @compileError;
inspecting the entire module using @typeInfo triggers those errors. Instead,
select only its actual extern function declarations. No per-function wrappers
or handwritten function lists are used.
"""
import pathlib
import re
import sys

if len(sys.argv) < 5:
    sys.exit("usage: auto_c_bindings.py <translated.zig> <output.zig> <module> <prefix> [revo_source.rv ...]")

source, output, module, prefix, *scripts = sys.argv[1:]
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", module):
    sys.exit("invalid Zig import name")
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", prefix):
    sys.exit("invalid C function prefix")

translated = pathlib.Path(source).read_text(encoding="utf-8")
# translate-c emits pub extern "c" fn ... or pub extern fn ...
names = sorted(set(re.findall(
    r'^\s*pub\s+extern\s+(?:"[^"]+"\s+)?fn\s+('
    + re.escape(prefix) + r'[A-Za-z0-9_]+)\s*\(',
    translated,
    flags=re.MULTILINE,
)))
if not names:
    sys.exit(f"no {prefix} extern functions found in {source}; verify translate-c format")

# Optional demand-driven mode: discover used native functions automatically
# in the supplied Revo scripts. Unrestricted builds (no .rv inputs) still
# export every compatible function without hand-maintained wrapper lists.
if scripts:
    used = set()
    for path in scripts:
        content = pathlib.Path(path).read_text(encoding="utf-8")
        used.update(re.findall(r"\\b" + re.escape(prefix) + r"[A-Za-z0-9_]+\\b", content))
    names = [name for name in names if name in used]
    if not names:
        sys.exit("no referenced C functions matched translated extern declarations")

lines = [
    '// GENERATED: only actual extern C functions, never translated macros.',
    'const revo = @import("revo");',
    f'const package = @import("{module}");',
    'const Functions = struct {',
]
for name in names:
    lines.append(f'    pub const {name} = package.raw.{name};')
lines += [
    '};',
    'pub export const revo_native_bindings_ex = revo.extension.autoBindings(Functions);',
    '',
]
pathlib.Path(output).write_text("\n".join(lines), encoding="utf-8")
print(f"Auto-bound {len(names)} translated C functions from {module}" + (" (used by Revo scripts)" if scripts else ""))
