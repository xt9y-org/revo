REVO ?= revo
ZIG ?= zig
OPTIMIZE ?= Debug
LIBEXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

.PHONY: all deps compile clean

all: compile
	$(REVO) main.rv

deps:
	$(ZIG) fetch --save=sdl3 git+https://github.com/zmscode/sdl3-zig.git

compile: deps
	$(ZIG) build -Doptimize=$(OPTIMIZE)
	cp zig-out/lib/libsdl3_revo.$(LIBEXT) sdl3_revo.so
	$(REVO) compile main.rv main.rvo

clean:
	rm -f main.rvo sdl3_revo.so
