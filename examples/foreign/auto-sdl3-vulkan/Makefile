REVO ?= revo
ZIG ?= zig
OPTIMIZE ?= Debug
LIBEXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

.PHONY: all deps compile clean

all: compile
	$(REVO) main.rv

deps:
	$(ZIG) fetch --save=sdl3 'git+https://github.com/zmscode/sdl3-zig.git'
	$(ZIG) fetch --save=vulkan_zig 'git+https://github.com/Snektron/vulkan-zig.git?ref=zig-0.17-compat'
	$(ZIG) fetch --save=vulkan_headers 'git+https://github.com/KhronosGroup/Vulkan-Headers.git'
	# Snektron's compatibility branch still uses pre-0.17 Build syntax.
	# Fix the fetched package build script, NOT any Vulkan API declarations.
	@python3 -c 'from pathlib import Path; paths=list(Path("zig-pkg").glob("vulkan-*/build.zig")); assert len(paths)==1, f"Expected one Vulkan package, found: {paths}"; p=paths[0]; s=p.read_text(); a="b.standardOptimizeOption(.{}) orelse .debug"; b="b.standardOptimizeOption(.{})"; assert a in s or b in s, "Unexpected upstream Vulkan build API"; p.write_text(s.replace(a,b)); print(f"Zig 0.17 build compatibility: {p}")'

compile: deps
	$(ZIG) build -Doptimize=$(OPTIMIZE)
	cp zig-out/lib/libsdl_revo.$(LIBEXT) sdl_revo.so
	cp zig-out/lib/libvulkan_revo.$(LIBEXT) vulkan_revo.so
	$(REVO) compile main.rv main.rvo

clean:
	rm -f main.rvo sdl_revo.so vulkan_revo.so
