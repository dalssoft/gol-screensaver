; constants.inc - Shared constants and macros
; Game of Life Screensaver - x86-64 Linux Assembly

%ifndef CONSTANTS_INC
%define CONSTANTS_INC

; --- Application constants ---
%define MAX_HEAT       10
%define DENSITY_THRESH 52          ; ~20% of 256
%define SCROLL_EVERY   3

; --- Linux syscall numbers ---
%define SYS_read       0
%define SYS_write      1
%define SYS_open       2
%define SYS_close      3
%define SYS_poll       7
%define SYS_rt_sigaction 13
%define SYS_ioctl      16
%define SYS_nanosleep  35
%define SYS_exit       60
%define SYS_clock_gettime 228

; --- File flags ---
%define O_RDONLY       0

; --- Terminal/ioctl constants ---
%define STDIN          0
%define STDOUT         1
%define TIOCGWINSZ     0x5413
%define TCGETS         0x5401
%define TCSETS         0x5402
%define POLLIN         1
%define ICANON         0x2
%define ECHO           0x8

; --- Signal constants ---
%define SIGINT         2
%define SIGTERM        15

; --- Clock constants ---
%define CLOCK_MONOTONIC 1

; --- Macros ---

; EMIT_BRAILLE - encode braille offset as 3-byte UTF-8 and write to [rdi]
; %1 = register containing braille offset (0-255), must NOT be ecx
; Braille range U+2800-U+28FF always encodes as: E2, A0|(n>>6), 80|(n&3F)
; Advances rdi by 3. Clobbers ecx.
%macro EMIT_BRAILLE 1
    mov byte [rdi], 0xE2
    mov ecx, %1
    shr ecx, 6
    or cl, 0xA0
    mov byte [rdi+1], cl
    mov ecx, %1
    and cl, 0x3F
    or cl, 0x80
    mov byte [rdi+2], cl
    add rdi, 3
%endmacro

; EMIT_ANSI_RESET - write ANSI reset sequence (\033[0m) to [rdi]
; Advances rdi. Clobbers rsi, ecx.
%macro EMIT_ANSI_RESET 0
    lea rsi, [ansi_reset]
    mov ecx, ansi_reset_len
    rep movsb
%endmacro

%endif
