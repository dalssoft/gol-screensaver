; data.asm - Constants, data section, and BSS buffers
; Game of Life - Braille Assembly Version

BITS 64
DEFAULT REL

; --- Constants ---
%define MAX_HEAT       10
%define SLEEP_MS       150000000   ; 150ms in nanoseconds
%define DENSITY_THRESH 52          ; ~20% of 256
%define SCROLL_EVERY   3

; Terminal defaults (overridden at runtime via ioctl)
%define DEFAULT_COLS   80
%define DEFAULT_LINES  24

; Max supported terminal: 320 cols x 100 lines -> grid 640x400
%define MAX_W          640
%define MAX_H          400
%define MAX_GRID       (MAX_W * MAX_H)    ; 256000

; Braille base codepoint U+2800
; UTF-8: E2 A0 80 + offset
%define BRAILLE_BASE_B0  0xE2
%define BRAILLE_BASE_B1  0xA0
%define BRAILLE_BASE_B2  0x80

; --- Exported symbols ---
global grid, grid2, heat, heat2
global grid_w, grid_h, char_cols, char_rows
global scroll_ox, scroll_oy, generation
global output_buf, output_pos
global timespec_sleep
global rng_state

; --- DATA section ---
section .data

; Heat foreground ANSI escape sequences (pointers + lengths)
; Index by heat value 0..10
global heat_fg_table, heat_fg_lens

; heat 0 = empty string (dead, no output)
heat_fg_0:  db 0
; heat 1 = \033[2;90m  (dim dark gray)
heat_fg_1:  db 27, '[2;90m'
; heat 2 = \033[90m    (dark gray)
heat_fg_2:  db 27, '[90m'
; heat 3 = \033[90m
heat_fg_3:  db 27, '[90m'
; heat 4 = \033[2;37m  (dim white)
heat_fg_4:  db 27, '[2;37m'
; heat 5 = \033[2;37m
heat_fg_5:  db 27, '[2;37m'
; heat 6 = \033[37m    (light gray)
heat_fg_6:  db 27, '[37m'
; heat 7 = \033[37m
heat_fg_7:  db 27, '[37m'
; heat 8 = \033[97m    (bright white)
heat_fg_8:  db 27, '[97m'
; heat 9 = \033[97m
heat_fg_9:  db 27, '[97m'
; heat 10 = \033[1;97m (bold bright white)
heat_fg_10: db 27, '[1;97m'

heat_fg_table:
    dq heat_fg_0
    dq heat_fg_1
    dq heat_fg_2
    dq heat_fg_3
    dq heat_fg_4
    dq heat_fg_5
    dq heat_fg_6
    dq heat_fg_7
    dq heat_fg_8
    dq heat_fg_9
    dq heat_fg_10

heat_fg_lens:
    dd 0     ; heat 0
    dd 7     ; heat 1: ESC[2;90m  (1+6=7)
    dd 5     ; heat 2: ESC[90m    (1+4=5)
    dd 5     ; heat 3: ESC[90m
    dd 7     ; heat 4: ESC[2;37m  (1+6=7)
    dd 7     ; heat 5: ESC[2;37m
    dd 5     ; heat 6: ESC[37m    (1+4=5)
    dd 5     ; heat 7: ESC[37m
    dd 5     ; heat 8: ESC[97m    (1+4=5)
    dd 5     ; heat 9: ESC[97m
    dd 7     ; heat 10: ESC[1;97m (1+6=7)

; ANSI reset sequence
global ansi_reset, ansi_reset_len
ansi_reset: db 27, '[0m'
ansi_reset_len equ $ - ansi_reset

; Cursor home
global ansi_home, ansi_home_len
ansi_home: db 27, '[H'
ansi_home_len equ $ - ansi_home

; Braille bit weights for 4x2 block positions
; Row 0: 0x01, 0x08
; Row 1: 0x02, 0x10
; Row 2: 0x04, 0x20
; Row 3: 0x40, 0x80
global braille_bits
braille_bits:
    db 0x01, 0x08   ; row 0
    db 0x02, 0x10   ; row 1
    db 0x04, 0x20   ; row 2
    db 0x40, 0x80   ; row 3

; Sleep timespec
timespec_sleep:
    dq 0                    ; tv_sec
    dq SLEEP_MS             ; tv_nsec

; Runtime grid dimensions
grid_w:     dd 0
grid_h:     dd 0
char_cols:  dd 0
char_rows:  dd 0

; Scroll offsets
scroll_ox:  dd 0
scroll_oy:  dd 0

; Generation counter
generation: dd 0

; RNG state
rng_state:  dq 0

; --- BSS section (uninitialized) ---
section .bss

grid:       resb MAX_GRID       ; current grid
grid2:      resb MAX_GRID       ; next grid (double buffer)
heat:       resb MAX_GRID       ; current heat map
heat2:      resb MAX_GRID       ; next heat map

; Output buffer (generous: 4 bytes per braille char + escapes + newlines)
; Max ~320 cols * 100 lines * 20 bytes = 640000
output_buf: resb 800000
output_pos: resq 1              ; current write position in output_buf
