REVO ?= revo
ZIG ?= zig
LIBEXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

.PHONY: all deps compile clean
all: compile
	$(REVO) main.rv

deps:
	$(ZIG) build --fetch

compile:
	$(ZIG) build -Doptimize=ReleaseFast
	cp zig-out/lib/libraylib_revo.$(LIBEXT) raylib_revo.so
	$(REVO) compile main.rv main.rvo

clean:
	rm -f main.rvo raylib_revo.so
