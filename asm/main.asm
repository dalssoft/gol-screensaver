; main.asm - Entry point and main loop
; Game of Life Screensaver - x86-64 Linux Assembly
; Designed for Linux framebuffer terminals (fbterm, kmscon, etc.)

BITS 64
DEFAULT REL

%define SYS_exit       60
%define SYS_rt_sigaction 13
%define SIGINT         2
%define SIGTERM        15
%define SCROLL_EVERY   3
%define RESET_EVERY    1000

; --- Imports ---
extern term_init, term_cleanup, term_get_size
extern term_flush, term_sleep, term_check_key
extern rng_init
extern grid_init, grid_step
extern render_frame
extern grid_w, grid_h
extern scroll_ox, scroll_oy, generation

; --- Exports ---
global _start

section .data

; sigaction struct for signal handling
; sa_handler (8 bytes) + sa_flags (8 bytes) + sa_restorer (8 bytes) + sa_mask (128 bytes)
align 8
sigact:
    dq signal_handler           ; sa_handler
    dq 0x04000000               ; sa_flags = SA_RESTORER
    dq sig_restorer             ; sa_restorer
    times 16 dq 0               ; sa_mask (128 bytes = 16 qwords)

section .text

; Signal restorer (required by kernel)
sig_restorer:
    mov eax, 15                 ; SYS_rt_sigreturn
    syscall

; signal_handler - handle SIGINT/SIGTERM gracefully
signal_handler:
    ; Cleanup terminal
    call term_cleanup

    ; Exit cleanly
    mov eax, SYS_exit
    xor edi, edi
    syscall

; setup_signals - install signal handlers for SIGINT and SIGTERM
setup_signals:
    ; sigaction(SIGINT, &sigact, NULL)
    mov eax, SYS_rt_sigaction
    mov edi, SIGINT
    lea rsi, [sigact]
    xor edx, edx               ; old_act = NULL
    mov r10d, 8                 ; sigsetsize
    syscall

    ; sigaction(SIGTERM, &sigact, NULL)
    mov eax, SYS_rt_sigaction
    mov edi, SIGTERM
    lea rsi, [sigact]
    xor edx, edx
    mov r10d, 8
    syscall
    ret

; _start - program entry point
_start:
    ; Setup signal handlers
    call setup_signals

    ; Detect terminal size
    call term_get_size

    ; Initialize terminal (clear, hide cursor)
    call term_init

    ; Seed PRNG
    call rng_init

; Main loop
.new_game:
    call grid_init
    mov dword [generation], 0

.main_loop:
    ; Render current state to output buffer
    call render_frame

    ; Flush output buffer to terminal
    call term_flush

    ; Check for keypress (any key exits)
    call term_check_key
    test eax, eax
    jnz .exit

    ; Advance simulation one step
    call grid_step

    ; Update generation counter
    mov eax, [generation]
    inc eax
    mov [generation], eax

    ; Reset after RESET_EVERY generations
    cmp eax, RESET_EVERY
    jge .new_game

    ; Scroll viewport every SCROLL_EVERY generations
    xor edx, edx
    mov ecx, SCROLL_EVERY
    div ecx
    test edx, edx
    jnz .no_scroll

    ; Advance scroll offsets (diagonal panning)
    mov eax, [scroll_ox]
    inc eax
    xor edx, edx
    div dword [grid_w]
    mov [scroll_ox], edx

    mov eax, [scroll_oy]
    inc eax
    xor edx, edx
    div dword [grid_h]
    mov [scroll_oy], edx

.no_scroll:
    ; Sleep
    call term_sleep

    jmp .main_loop

.exit:
    call term_cleanup
    mov eax, SYS_exit
    xor edi, edi
    syscall
