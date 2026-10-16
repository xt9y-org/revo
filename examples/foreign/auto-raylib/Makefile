REVO ?= revo
ZIG ?= zig
LIBEXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

.PHONY: all deps compile clean
all: compile
	$(REVO) main.rv

deps:
	@if command -v brew >/dev/null 2>&1 && ! brew list --versions raylib >/dev/null 2>&1; then brew install raylib; fi
	$(ZIG) fetch --save=raylib_zig 'git+https://github.com/raylib-zig/raylib-zig.git?ref=zig-17'
	$(ZIG) build --fetch

compile:
	$(ZIG) build -Doptimize=ReleaseFast
	cp zig-out/lib/libraylib_revo.$(LIBEXT) raylib_revo.so
	$(REVO) compile main.rv main.rvo

clean:
	rm -f main.rvo raylib_revo.so
