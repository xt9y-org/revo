REVO ?= revo
ZIG ?= zig
LIBEXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

.PHONY: all deps compile clean
all: compile
	$(REVO) main.rv

deps:
	$(ZIG) fetch --save=raylib_zig 'git+https://github.com/raylib-zig/raylib-zig.git?ref=zig-17'
	$(ZIG) fetch --save=raylib 'git+https://github.com/raysan5/raylib.git#2dee47282ae75d241759cc35f22e4768dcd092be'
	$(ZIG) build --fetch

compile: deps
	$(ZIG) build -Doptimize=ReleaseFast
	cp zig-out/lib/libraylib_revo.$(LIBEXT) raylib_revo.so
	$(REVO) compile main.rv main.rvo

clean:
	rm -f main.rvo raylib_revo.so
