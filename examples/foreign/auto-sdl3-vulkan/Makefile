REVO ?= revo
ZIG ?= zig
LIBEXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

.PHONY: all deps compile clean

all: compile
	$(REVO) main.rv

deps:
	$(ZIG) fetch --save=sdl3 'git+https://github.com/zmscode/sdl3-zig.git'
	$(ZIG) fetch --save=vulkan_zig 'git+https://github.com/Snektron/vulkan-zig.git?ref=zig-0.17-compat'
	$(ZIG) fetch --save=vulkan_headers 'git+https://github.com/KhronosGroup/Vulkan-Headers.git'

compile:
	$(ZIG) build -Doptimize=ReleaseFast
	cp zig-out/lib/libsdl_revo.$(LIBEXT) sdl_revo.so
	cp zig-out/lib/libvulkan_revo.$(LIBEXT) vulkan_revo.so
	$(REVO) compile main.rv main.rvo

clean:
	rm -f main.rvo sdl_revo.so vulkan_revo.so
