; grid.asm - Grid initialization and Game of Life step with SSE2 SIMD
; Uses shifted-grid approach for neighbor counting (like NumPy np.roll)
; Processes 16 cells at a time with packed byte operations

BITS 64
DEFAULT REL

%include "constants.inc"

extern grid, grid2, heat, heat2
extern grid_w, grid_h
extern rng_next

global grid_init
global grid_step

section .data
align 16
vec_one:    times 16 db 1
vec_two:    times 16 db 2
vec_three:  times 16 db 3
vec_maxheat: times 16 db MAX_HEAT

section .text

; grid_init - initialize grid with ~20% random density
grid_init:
    push rbx
    push r12

    mov r12d, [grid_h]
    imul r12d, [grid_w]            ; total cells

    xor ebx, ebx
.init_loop:
    cmp ebx, r12d
    jge .init_done

    call rng_next
    movzx ecx, al
    cmp cl, DENSITY_THRESH
    jae .dead

    mov byte [grid + rbx], 1
    mov byte [heat + rbx], MAX_HEAT
    jmp .next
.dead:
    mov byte [grid + rbx], 0
    mov byte [heat + rbx], 0
.next:
    inc ebx
    jmp .init_loop

.init_done:
    pop r12
    pop rbx
    ret

; add_shifted - add shifted grid to neighbor accumulator
; rdi = dest (neighbor count buffer, accumulated)
; rsi = source grid
; edx = row_shift (-1, 0, +1)
; ecx = col_shift (-1, 0, +1)
; r8d = H, r9d = W, r10d = total cells
; Adds source[wrapped(r+dr, c+dc)] to dest[r*W+c] for all cells
; Uses SSE2 to add 16 cells at a time
;
; Strategy: instead of wrapping per-cell, we compute a source pointer
; that is offset by (dr*W + dc), and handle the wrap by copying
; edge rows/cols. But simpler: just do row-by-row with memcpy-style offset.
;
; Simplest SIMD approach: compute source offset, then add with wrap.
; For toroidal: src_row = (r + dr + H) % H, src_col = (c + dc + W) % W
; We precompute the shifted grid into grid2 as temp, then SIMD-add to dest.

; Actually, the fastest approach: for each of 8 neighbors, compute the
; linear offset = dr * W + dc, then add grid[i + offset] to neighbors[i],
; handling wrap at boundaries.
; For bulk of grid (not edges), offset is constant and we can blast through
; with SSE2. Edges need special handling.

; grid_step - advance one generation using SIMD
; 1. Clear neighbor count buffer (grid2 used as temp)
; 2. For each of 8 directions, add shifted grid to neighbor count
; 3. Apply GoL rules with SIMD
; 4. Update heat with SIMD
; 5. Swap buffers
grid_step:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 8                     ; align stack to 16

    mov r14d, [grid_h]             ; H
    mov r15d, [grid_w]             ; W
    mov ebp, r14d
    imul ebp, r15d                 ; total = H * W

    ; Step 1: Clear grid2 (used as neighbor count buffer)
    xor eax, eax
    pxor xmm0, xmm0
    mov ecx, ebp
    shr ecx, 4                     ; count / 16
    lea rdi, [grid2]
.clear_loop:
    test ecx, ecx
    jz .clear_remainder
    movdqu [rdi], xmm0
    add rdi, 16
    dec ecx
    jmp .clear_loop
.clear_remainder:
    ; Handle remaining bytes
    mov ecx, ebp
    and ecx, 0xF
.clear_tail:
    test ecx, ecx
    jz .clear_done
    mov byte [rdi], 0
    inc rdi
    dec ecx
    jmp .clear_tail
.clear_done:

    ; Step 2: For each of 8 directions, add shifted neighbor
    ; Directions: (-1,-1) (-1,0) (-1,1) (0,-1) (0,1) (1,-1) (1,0) (1,1)

    ; Process direction (-1, -1)
    mov edi, -1
    mov esi, -1
    call .add_direction

    ; (-1, 0)
    mov edi, -1
    xor esi, esi
    call .add_direction

    ; (-1, +1)
    mov edi, -1
    mov esi, 1
    call .add_direction

    ; (0, -1)
    xor edi, edi
    mov esi, -1
    call .add_direction

    ; (0, +1)
    xor edi, edi
    mov esi, 1
    call .add_direction

    ; (1, -1)
    mov edi, 1
    mov esi, -1
    call .add_direction

    ; (1, 0)
    mov edi, 1
    xor esi, esi
    call .add_direction

    ; (1, +1)
    mov edi, 1
    mov esi, 1
    call .add_direction

    ; Step 3 & 4: Apply GoL rules + update heat using SSE2
    ; grid2[i] = neighbor count
    ; new_alive = (n == 3) || (grid[i] && n == 2)
    ; new_heat = new_alive ? MAX_HEAT : max(heat[i] - 1, 0)

    movdqa xmm4, [vec_two]        ; xmm4 = 2 in all bytes
    movdqa xmm5, [vec_three]      ; xmm5 = 3 in all bytes
    movdqa xmm6, [vec_maxheat]    ; xmm6 = MAX_HEAT in all bytes
    movdqa xmm7, [vec_one]        ; xmm7 = 1 in all bytes

    xor ebx, ebx                  ; index
.rules_loop:
    mov eax, ebp
    sub eax, ebx
    cmp eax, 16
    jl .rules_tail

    ; Load 16 cells
    movdqu xmm0, [grid2 + rbx]    ; xmm0 = neighbor counts
    movdqu xmm1, [grid + rbx]     ; xmm1 = current alive state
    movdqu xmm2, [heat + rbx]     ; xmm2 = current heat

    ; n == 3 -> birth or survive
    movdqa xmm3, xmm0
    pcmpeqb xmm3, xmm5            ; xmm3 = 0xFF where n==3

    ; n == 2 AND alive -> survive
    movdqa xmm8, xmm0
    pcmpeqb xmm8, xmm4            ; xmm8 = 0xFF where n==2
    ; alive: need non-zero check -> compare grid[i] with 0
    pxor xmm9, xmm9
    movdqa xmm10, xmm1
    pcmpeqb xmm10, xmm9           ; xmm10 = 0xFF where dead
    pandn xmm10, xmm8             ; xmm10 = 0xFF where (alive AND n==2)

    ; new_alive_mask = (n==3) OR (alive AND n==2)
    por xmm3, xmm10               ; xmm3 = 0xFF where new cell is alive

    ; New grid value: 1 where alive, 0 where dead
    movdqa xmm1, xmm3
    pand xmm1, xmm7               ; xmm1 = 1 where alive, 0 where dead
    movdqu [heat2 + rbx], xmm1    ; temp store new grid in heat2

    ; Heat update:
    ; alive -> MAX_HEAT
    ; dead -> saturating subtract 1 from current heat
    movdqa xmm8, xmm2
    psubusb xmm8, xmm7            ; xmm8 = max(heat - 1, 0)

    ; Select: alive ? MAX_HEAT : (heat - 1)
    ; mask xmm3 = 0xFF for alive
    movdqa xmm9, xmm6             ; MAX_HEAT
    pand xmm9, xmm3               ; MAX_HEAT where alive
    pandn xmm3, xmm8              ; (heat-1) where dead
    por xmm9, xmm3                ; combined heat

    ; Store results
    ; Copy new grid from heat2 to grid
    movdqu xmm0, [heat2 + rbx]
    movdqu [grid + rbx], xmm0
    movdqu [heat + rbx], xmm9

    add ebx, 16
    jmp .rules_loop

.rules_tail:
    ; Handle remaining cells one by one
    cmp ebx, ebp
    jge .step_done

    movzx eax, byte [grid2 + rbx] ; neighbor count
    movzx ecx, byte [grid + rbx]  ; alive
    movzx edx, byte [heat + rbx]  ; current heat

    ; GoL rules
    cmp al, 3
    je .tail_alive
    cmp al, 2
    jne .tail_dead
    test cl, cl
    jnz .tail_alive

.tail_dead:
    mov byte [grid + rbx], 0
    ; heat = max(heat - 1, 0)
    test dl, dl
    jz .tail_heat_zero
    dec dl
.tail_heat_zero:
    mov byte [heat + rbx], dl
    jmp .tail_next

.tail_alive:
    mov byte [grid + rbx], 1
    mov byte [heat + rbx], MAX_HEAT

.tail_next:
    inc ebx
    jmp .rules_tail

.step_done:
    add rsp, 8
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; .add_direction - add grid shifted by (dr, dc) to neighbor count in grid2
; edi = dr (-1, 0, +1), esi = dc (-1, 0, +1)
; Uses r14=H, r15=W, ebp=total
.add_direction:
    push r12
    push r13
    push rbx

    ; For each row r in [0, H):
    ;   src_row = (r + dr + H) % H
    ;   For each col c in [0, W):
    ;     src_col = (c + dc + W) % W
    ;     grid2[r*W + c] += grid[src_row*W + src_col]
    ;
    ; Optimization: for each row, the source row is fixed.
    ; For columns: if dc==0, source is same column -> can SIMD the whole row.
    ; If dc==-1: source is shifted left by 1 (with wrap of last col).
    ; If dc==+1: source is shifted right by 1 (with wrap of first col).

    mov r12d, edi                  ; dr
    mov r13d, esi                  ; dc

    xor ebx, ebx                   ; row = 0

.dir_row_loop:
    cmp ebx, r14d
    jge .dir_done

    ; src_row = (row + dr + H) % H
    lea eax, [ebx + r12d]
    add eax, r14d
    xor edx, edx
    div r14d
    ; edx = src_row
    imul edx, r15d                 ; edx = src_row * W = source row offset

    ; dest offset = row * W
    mov eax, ebx
    imul eax, r15d                 ; eax = dest row offset

    ; Now add source row (shifted by dc) to dest row using SSE2
    ; r8 = dest base (grid2 + dest_offset)
    ; r9 = src base (grid + src_offset)
    lea r8, [grid2 + rax]
    lea r9, [grid + rdx]

    test r13d, r13d
    jz .dir_dc_zero
    cmp r13d, -1
    je .dir_dc_neg
    jmp .dir_dc_pos

.dir_dc_zero:
    ; dc == 0: straight copy-add, no column shift
    xor ecx, ecx                  ; col = 0
.dc0_loop:
    mov eax, r15d
    sub eax, ecx
    cmp eax, 16
    jl .dc0_tail

    movdqu xmm0, [r8 + rcx]      ; dest
    movdqu xmm1, [r9 + rcx]      ; src (same columns)
    paddb xmm0, xmm1
    movdqu [r8 + rcx], xmm0
    add ecx, 16
    jmp .dc0_loop

.dc0_tail:
    cmp ecx, r15d
    jge .dir_row_next
    movzx eax, byte [r8 + rcx]
    add al, byte [r9 + rcx]
    mov byte [r8 + rcx], al
    inc ecx
    jmp .dc0_tail

.dir_dc_neg:
    ; dc == -1: source col = (c - 1 + W) % W
    ; For c=0: src_col = W-1 (wrap)
    ; For c=1..W-1: src_col = c-1 (just offset by -1)

    ; Handle c=0 specially (wraps to W-1)
    movzx eax, byte [r8]
    mov ecx, r15d
    dec ecx                        ; W-1
    add al, byte [r9 + rcx]
    mov byte [r8], al

    ; c=1..W-1: src is [r9 + c - 1], dest is [r8 + c]
    mov ecx, 1
.dcn_loop:
    mov eax, r15d
    sub eax, ecx
    cmp eax, 16
    jl .dcn_tail

    movdqu xmm0, [r8 + rcx]          ; dest[c]
    movdqu xmm1, [r9 + rcx - 1]      ; src[c-1]
    paddb xmm0, xmm1
    movdqu [r8 + rcx], xmm0
    add ecx, 16
    jmp .dcn_loop

.dcn_tail:
    cmp ecx, r15d
    jge .dir_row_next
    movzx eax, byte [r8 + rcx]
    add al, byte [r9 + rcx - 1]
    mov byte [r8 + rcx], al
    inc ecx
    jmp .dcn_tail

.dir_dc_pos:
    ; dc == +1: source col = (c + 1) % W
    ; For c=W-1: src_col = 0 (wrap)
    ; For c=0..W-2: src_col = c+1

    ; Handle c=0..W-2: src is [r9 + c + 1], dest is [r8 + c]
    xor ecx, ecx
    mov eax, r15d
    dec eax                        ; last = W-1

.dcp_loop:
    mov edx, eax                   ; last col index (W-1)
    sub edx, ecx
    cmp edx, 16
    jl .dcp_tail

    movdqu xmm0, [r8 + rcx]          ; dest[c]
    movdqu xmm1, [r9 + rcx + 1]      ; src[c+1]
    paddb xmm0, xmm1
    movdqu [r8 + rcx], xmm0
    add ecx, 16
    jmp .dcp_loop

.dcp_tail:
    ; Scalar for remaining up to W-2
    mov edx, r15d
    dec edx                        ; W-1
    cmp ecx, edx
    jge .dcp_wrap

    movzx eax, byte [r8 + rcx]
    add al, byte [r9 + rcx + 1]
    mov byte [r8 + rcx], al
    inc ecx
    jmp .dcp_tail

.dcp_wrap:
    ; Handle c=W-1: wraps to src_col=0
    mov ecx, r15d
    dec ecx                        ; c = W-1
    movzx eax, byte [r8 + rcx]
    add al, byte [r9]             ; src[0]
    mov byte [r8 + rcx], al

.dir_row_next:
    inc ebx
    jmp .dir_row_loop

.dir_done:
    pop rbx
    pop r13
    pop r12
    ret
