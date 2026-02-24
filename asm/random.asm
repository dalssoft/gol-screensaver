; random.asm - Xorshift64 PRNG
; Fast, simple pseudo-random number generator

BITS 64
DEFAULT REL

%include "constants.inc"

extern rng_state

global rng_init
global rng_next

section .bss
timespec_buf: resb 16

section .text

; rng_init - seed the PRNG from clock_gettime
rng_init:
    ; clock_gettime(CLOCK_MONOTONIC, &timespec_buf)
    mov eax, SYS_clock_gettime
    mov edi, CLOCK_MONOTONIC
    lea rsi, [timespec_buf]
    syscall

    ; Combine seconds and nanoseconds for seed
    mov rax, [timespec_buf]         ; tv_sec
    mov rcx, [timespec_buf + 8]     ; tv_nsec
    mov rdx, 6364136223846793005
    imul rax, rdx
    xor rax, rcx
    ; Ensure non-zero
    test rax, rax
    jnz .store
    mov rax, 0x123456789ABCDEF0
.store:
    mov [rng_state], rax
    ret

; rng_next - return next pseudo-random 64-bit value in rax
; Xorshift64 algorithm
rng_next:
    mov rax, [rng_state]
    mov rcx, rax
    shl rcx, 13
    xor rax, rcx
    mov rcx, rax
    shr rcx, 7
    xor rax, rcx
    mov rcx, rax
    shl rcx, 17
    xor rax, rcx
    mov [rng_state], rax
    ret
