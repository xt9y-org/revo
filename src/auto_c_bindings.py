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

if len(sys.argv) != 5:
    sys.exit("usage: auto_c_bindings.py <translated.zig> <output.zig> <module> <prefix>")

source, output, module, prefix = sys.argv[1:]
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
print(f"Auto-bound {len(names)} translated C function declarations from {module}")
