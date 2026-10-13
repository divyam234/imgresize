ZIG ?= zig
OPTIMIZE ?= ReleaseFast

all:
	$(ZIG) build -Doptimize=$(OPTIMIZE)

run:
	$(ZIG) build run -Doptimize=$(OPTIMIZE)

test:
	$(ZIG) build test -Doptimize=Debug

clean:
	rm -rf .zig-cache zig-out

.PHONY: all run test clean
