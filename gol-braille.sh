#!/bin/bash
# Game of Life - Braille with color heat map (numpy optimized)
export TERM=${TERM:-xterm-256color}
trap 'tput cnorm; exit' INT TERM
tput civis
clear

python3 << 'PYTHON'
import numpy as np
import time, os, signal, sys, shutil

def handler(sig, frame):
    print('\033[?25h\033[0m', end='')
    sys.exit(0)
signal.signal(signal.SIGINT, handler)

size = shutil.get_terminal_size((80, 24))
cols = size.columns
lines = size.lines

W = cols * 2
H = lines * 4
MAX_HEAT = 10
CHAR_ROWS = H // 4
CHAR_COLS = W // 2

HEAT_FG = [
    '',            # 0  dead
    '\033[2;90m',  # 1  dim dark gray
    '\033[90m',    # 2  dark gray
    '\033[90m',    # 3  dark gray
    '\033[2;37m',  # 4  dim white (gray)
    '\033[2;37m',  # 5  dim white (gray)
    '\033[37m',    # 6  white (light gray)
    '\033[37m',    # 7  white (light gray)
    '\033[97m',    # 8  bright white
    '\033[97m',    # 9  bright white
    '\033[1;97m',  # 10 bold bright white (alive)
]

def count_neighbors(grid):
    n = np.zeros_like(grid, dtype=np.int8)
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            if dr == 0 and dc == 0:
                continue
            n += np.roll(np.roll(grid, -dr, axis=0), -dc, axis=1)
    return n

# Precompute braille chars
BRAILLE = [chr(0x2800 + i) for i in range(256)]

ox = 0
oy = 0

def render(visible, heat_vis):
    # visible: bool grid (H, W) already scrolled
    # heat_vis: int8 grid (H, W) already scrolled

    # Compute braille values for each 2x4 block using numpy
    # Reshape into blocks of (CHAR_ROWS, 4, CHAR_COLS, 2)
    vis = (visible | (heat_vis > 0)).astype(np.uint8)
    vis_blocks = vis.reshape(CHAR_ROWS, 4, CHAR_COLS, 2)

    # Bit values for each position in 4x2 block
    bits = np.array([[0x01, 0x08],
                     [0x02, 0x10],
                     [0x04, 0x20],
                     [0x40, 0x80]], dtype=np.uint8)

    # Multiply and sum: (CHAR_ROWS, 4, CHAR_COLS, 2) * (4, 2) -> sum over axes 1,3
    braille_vals = np.einsum('ijkl,jl->ik', vis_blocks, bits)

    # Max heat per character block
    heat_blocks = heat_vis.reshape(CHAR_ROWS, 4, CHAR_COLS, 2)
    max_heat = heat_blocks.max(axis=(1, 3))

    # Build output string
    buf = []
    for r in range(CHAR_ROWS):
        line = ['\033[0m']
        prev_fg = ''
        row_vals = braille_vals[r]
        row_heat = max_heat[r]
        for c in range(CHAR_COLS):
            v = int(row_vals[c])
            h = int(row_heat[c])
            if v == 0:
                if prev_fg:
                    line.append('\033[0m')
                    prev_fg = ''
                line.append(' ')
            else:
                fg = HEAT_FG[min(h, MAX_HEAT)]
                if fg != prev_fg:
                    line.append(fg)
                    prev_fg = fg
                line.append(BRAILLE[v])
        line.append('\033[0m')
        buf.append(''.join(line))
    return '\n'.join(buf)

grid = (np.random.random((H, W)) < 0.20).astype(np.int8)
heat = np.where(grid, MAX_HEAT, 0).astype(np.int8)

gen = 0
while True:
    # Scroll view
    visible = np.roll(np.roll(grid, -oy, axis=0), -ox, axis=1)
    heat_vis = np.roll(np.roll(heat, -oy, axis=0), -ox, axis=1)

    frame = render(visible, heat_vis)
    sys.stdout.write(f'\033[H{frame}')
    sys.stdout.flush()

    n = count_neighbors(grid)
    new = ((n == 3) | (grid & (n == 2))).astype(np.int8)
    heat = np.where(new, MAX_HEAT, np.maximum(heat - 1, 0)).astype(np.int8)

    grid = new
    gen += 1
    if gen % 3 == 0:
        ox = (ox + 1) % W
        oy = (oy + 1) % H
    time.sleep(0.15)
PYTHON
