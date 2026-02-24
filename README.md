# Game of Life Screensaver

Conway's Game of Life as a terminal screensaver in pure **x86-64 Linux assembly** — no libc, just syscalls.

<video src="https://github.com/user-attachments/assets/3680099e-46a4-404c-ad2e-acc76077ddc2" autoplay loop muted playsinline></video>

Uses **braille Unicode characters** (U+2800–U+28FF) to maximize the playing field: each terminal character maps to a 2x4 cell block, giving 8x the resolution of regular text. A standard 80x24 terminal becomes a 160x96 grid. SSE2 SIMD keeps CPU usage around 1-2%.

## Features

- **High-density display** — braille characters pack 8 cells per glyph, filling the entire terminal with the game grid
- **SSE2 SIMD** — neighbor counting and GoL rules applied 16 cells at a time using packed byte operations
- **Heat map decay** — dead cells fade through grayscale gradients over 10 generations
- **Toroidal grid** — edges wrap seamlessly in both directions
- **Viewport scrolling** — diagonal panning across the grid
- **Pure syscalls** — no libc dependency, statically linked ~9KB binary
- **Signal handling** — clean exit on SIGINT/SIGTERM, restores cursor

## Requirements

- Linux x86-64 with a terminal that supports UTF-8 and ANSI escape codes
- Docker (for cross-compilation from macOS/ARM64)
- Or: NASM + GNU ld on a native x86-64 Linux system

## Build

Cross-compile via Docker (works from macOS ARM64):

```
cd asm
make build
```

Or build natively on x86-64 Linux:

```
cd asm
make _build
```

This produces a statically linked `gol-braille` binary (~9KB).

## Run

```
./gol-braille
```

Press any key to exit. The terminal is restored automatically. The simulation resets with a new random grid every 1000 generations.

The program auto-detects terminal dimensions via `ioctl(TIOCGWINSZ)` and adapts the grid accordingly.

## Architecture

| Module         | Description                                         |
|----------------|-----------------------------------------------------|
| `main.asm`     | Entry point, main loop, signal handlers             |
| `grid.asm`     | SSE2 SIMD Game of Life step + heat propagation      |
| `render.asm`   | Braille UTF-8 encoding with heat-map ANSI coloring  |
| `terminal.asm` | Terminal setup/teardown, size detection, raw I/O     |
| `random.asm`   | Xorshift64 PRNG seeded from `clock_gettime`         |
| `data.asm`     | Constants, ANSI escape tables, BSS buffers           |

### How it works

1. A 2D grid is initialized with ~20% random density
2. Each generation applies standard GoL rules (B3/S23) using SSE2:
   - 8 shifted copies of the grid are summed with `paddb` for neighbor counts
   - Rules are evaluated with `pcmpeqb`, `pand`, `por`, `pandn`
   - Heat map tracks recently alive cells, decayed with `psubusb`
3. The renderer maps each 2x4 block of cells to a braille character
4. Cells are colored by heat level using ANSI grayscale escapes
5. The viewport scrolls diagonally across the toroidal grid

## License

[MIT](LICENSE)
