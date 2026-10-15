REVO ?= revo
ZIG ?= zig
LIBEXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

.PHONY: all deps compile clean

all: compile
	$(REVO) main.rv

deps:
	$(ZIG) fetch --save=sdl3 git+https://github.com/zmscode/sdl3-zig.git

compile:
	$(ZIG) build -Doptimize=ReleaseFast
	cp zig-out/lib/libsdl3_revo.$(LIBEXT) sdl3_revo.so
	$(REVO) compile main.rv main.rvo

clean:
	rm -f main.rvo sdl3_revo.so
