; terminal.asm - Terminal setup, teardown, size detection, raw output
; Uses Linux syscalls directly (no libc)

BITS 64
DEFAULT REL

; Syscall numbers
%define SYS_read       0
%define SYS_write      1
%define SYS_poll       7
%define SYS_ioctl      16
%define SYS_nanosleep  35
%define SYS_exit       60

; ioctl constants
%define TIOCGWINSZ     0x5413
%define TCGETS         0x5401
%define TCSETS         0x5402
%define STDOUT         1
%define STDIN          0

; poll constants
%define POLLIN         1

; termios c_lflag bits
%define ICANON         0x2
%define ECHO           0x8

; --- Imports ---
extern grid_w, grid_h, char_cols, char_rows
extern output_buf, output_pos
extern timespec_sleep
extern ansi_home, ansi_home_len
extern ansi_reset, ansi_reset_len

; --- Exports ---
global term_init
global term_cleanup
global term_get_size
global term_flush
global term_sleep
global term_check_key
global term_write_home
global buf_reset
global buf_append
global buf_append_byte
global buf_append_newline

section .data

; Hide cursor: \033[?25l
seq_hide_cursor: db 27, '[?25l'
seq_hide_cursor_len equ $ - seq_hide_cursor

; Show cursor: \033[?25h
seq_show_cursor: db 27, '[?25h'
seq_show_cursor_len equ $ - seq_show_cursor

; Clear screen: \033[2J
seq_clear: db 27, '[2J'
seq_clear_len equ $ - seq_clear

section .bss
; winsize struct: unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel
winsize: resb 8
; termios structs (60 bytes each)
old_termios: resb 60
new_termios: resb 60
; pollfd struct: int fd (4) + short events (2) + short revents (2)
pollfd: resb 8
; key read buffer
keybuf: resb 1

section .text

; term_get_size - detect terminal size via ioctl TIOCGWINSZ
; Sets grid_w, grid_h, char_cols, char_rows
; Returns: eax = 0 on success
term_get_size:
    push rbx

    ; ioctl(STDOUT, TIOCGWINSZ, &winsize)
    mov eax, SYS_ioctl
    mov edi, STDOUT
    mov esi, TIOCGWINSZ
    lea rdx, [winsize]
    syscall

    test eax, eax
    jnz .use_defaults

    ; Read rows and cols
    movzx eax, word [winsize]       ; ws_row (lines)
    movzx ebx, word [winsize + 2]   ; ws_col (cols)

    ; Validate
    test eax, eax
    jz .use_defaults
    test ebx, ebx
    jz .use_defaults

    jmp .set_dims

.use_defaults:
    mov eax, 24         ; DEFAULT_LINES
    mov ebx, 80         ; DEFAULT_COLS

.set_dims:
    ; char_rows = lines, char_cols = cols
    mov [char_rows], eax
    mov [char_cols], ebx

    ; grid_h = lines * 4
    shl eax, 2
    mov [grid_h], eax

    ; grid_w = cols * 2
    shl ebx, 1
    mov [grid_w], ebx

    xor eax, eax
    pop rbx
    ret

; term_init - setup terminal (raw mode, hide cursor, clear screen)
term_init:
    ; Save current termios
    mov eax, SYS_ioctl
    mov edi, STDIN
    mov esi, TCGETS
    lea rdx, [old_termios]
    syscall

    ; Copy to new_termios
    lea rsi, [old_termios]
    lea rdi, [new_termios]
    mov ecx, 60
    rep movsb

    ; Disable ICANON and ECHO in c_lflag (offset 12)
    mov eax, [new_termios + 12]
    and eax, ~(ICANON | ECHO)
    mov [new_termios + 12], eax

    ; Apply new termios
    mov eax, SYS_ioctl
    mov edi, STDIN
    mov esi, TCSETS
    lea rdx, [new_termios]
    syscall

    ; Setup pollfd for stdin
    mov dword [pollfd], STDIN       ; fd = 0
    mov word [pollfd + 4], POLLIN   ; events = POLLIN
    mov word [pollfd + 6], 0        ; revents = 0

    ; Clear screen
    mov eax, SYS_write
    mov edi, STDOUT
    lea rsi, [seq_clear]
    mov edx, seq_clear_len
    syscall

    ; Hide cursor
    mov eax, SYS_write
    mov edi, STDOUT
    lea rsi, [seq_hide_cursor]
    mov edx, seq_hide_cursor_len
    syscall

    ret

; term_cleanup - restore terminal (termios, stdin flags, show cursor, reset colors)
term_cleanup:
    ; Restore termios
    mov eax, SYS_ioctl
    mov edi, STDIN
    mov esi, TCSETS
    lea rdx, [old_termios]
    syscall

    ; Reset colors
    mov eax, SYS_write
    mov edi, STDOUT
    lea rsi, [ansi_reset]
    mov edx, ansi_reset_len
    syscall

    ; Show cursor
    mov eax, SYS_write
    mov edi, STDOUT
    lea rsi, [seq_show_cursor]
    mov edx, seq_show_cursor_len
    syscall

    ret

; term_flush - write output_buf to stdout
; Writes from output_buf[0] to output_buf[output_pos]
term_flush:
    mov rsi, output_buf
    mov rdx, [output_pos]
    test rdx, rdx
    jz .done
    mov eax, SYS_write
    mov edi, STDOUT
    syscall
.done:
    ret

; term_check_key - non-blocking check if any key was pressed
; Uses poll() with timeout=0 to avoid O_NONBLOCK side effects
; Returns: eax = 1 if key pressed, 0 if not
term_check_key:
    ; poll(&pollfd, 1, 0) — timeout 0 = non-blocking
    mov eax, SYS_poll
    lea rdi, [pollfd]
    mov esi, 1                     ; nfds = 1
    xor edx, edx                   ; timeout = 0
    syscall

    ; eax > 0 means fd is ready
    test eax, eax
    jle .no_key

    ; Consume the byte
    mov eax, SYS_read
    mov edi, STDIN
    lea rsi, [keybuf]
    mov edx, 1
    syscall

    mov eax, 1
    ret
.no_key:
    xor eax, eax
    ret

; term_sleep - sleep for SLEEP_MS nanoseconds
term_sleep:
    mov eax, SYS_nanosleep
    lea rdi, [timespec_sleep]
    xor esi, esi            ; NULL (no remaining time)
    syscall
    ret

; term_write_home - append cursor home sequence to output buffer
term_write_home:
    lea rsi, [ansi_home]
    mov ecx, ansi_home_len
    jmp buf_append

; buf_reset - reset output buffer position to 0
buf_reset:
    mov qword [output_pos], 0
    ret

; buf_append - append ecx bytes from rsi to output buffer
; rsi = source, ecx = length
buf_append:
    push rdi
    push rsi
    push rcx

    mov rdi, output_buf
    add rdi, [output_pos]
    ; ecx bytes from rsi to rdi
    rep movsb
    ; Update position
    pop rcx
    sub rdi, output_buf
    mov [output_pos], rdi

    pop rsi
    pop rdi
    ret

; buf_append_byte - append single byte al to output buffer
buf_append_byte:
    push rdi
    mov rdi, output_buf
    add rdi, [output_pos]
    stosb
    sub rdi, output_buf
    mov [output_pos], rdi
    pop rdi
    ret

; buf_append_newline - append '\n' to output buffer
buf_append_newline:
    mov al, 10
    jmp buf_append_byte
