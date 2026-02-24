# Makefile - Game of Life Screensaver (x86-64 Linux Assembly)
# Cross-compiles from macOS/ARM64 via Docker

NASM      = nasm
LD        = ld
NFLAGS    = -f elf64 -g -F dwarf
LDFLAGS   = -s

TARGET    = gol-braille

DOCKER_IMG  = debian:bookworm
DOCKER_PKGS = nasm binutils make file
DOCKER_RUN  = docker run --rm --platform linux/amd64 \
              -v "$$(pwd)":/src -w /src $(DOCKER_IMG) \
              bash -c "apt-get update -qq && \
              apt-get install -y -qq $(DOCKER_PKGS) > /dev/null 2>&1 && \
              make _build"

# Source modules
SRCS = main.asm terminal.asm random.asm grid.asm render.asm sysinfo.asm data.asm
OBJS = $(SRCS:.asm=.o)

.PHONY: all build clean help _build

# Default: cross-compile via Docker
all: build

# Cross-compile inside Docker (main entry point)
build:
	$(DOCKER_RUN)

# Internal target called inside Docker container
_build: clean $(TARGET)
	@echo "Build OK: $(TARGET) ($$(stat -c%s $(TARGET) 2>/dev/null || stat -f%z $(TARGET)) bytes)"
	@file $(TARGET)
	rm -f $(OBJS)

$(TARGET): $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $^

%.o: %.asm
	$(NASM) $(NFLAGS) -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

help:
	@echo "Game of Life Screensaver - x86-64 Assembly"
	@echo ""
	@echo "  make build    Cross-compile via Docker (default)"
	@echo "  make clean    Remove build artifacts"
	@echo "  make help     Show this message"

# Module dependencies
main.o:     main.asm
terminal.o: terminal.asm
random.o:   random.asm
grid.o:     grid.asm
render.o:   render.asm
sysinfo.o:  sysinfo.asm
data.o:     data.asm
