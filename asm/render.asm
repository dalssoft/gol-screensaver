; render.asm - Braille rendering with heat-map coloring (optimized)
; Reads grid[] and heat[] with scroll offsets, outputs to buffer
; Avoids per-cell function calls; uses direct indexed access

BITS 64
DEFAULT REL

%include "constants.inc"

extern grid, heat
extern grid_w, grid_h, char_cols, char_rows
extern scroll_ox, scroll_oy
extern heat_fg_table, heat_fg_lens
extern ansi_reset, ansi_reset_len
extern output_buf, output_pos
extern ansi_home, ansi_home_len
extern buf_reset, buf_append
extern sysinfo_enabled, panel_x, panel_y, panel_w
extern panel_row_off, panel_row_len, panel_buf
extern sysinfo_prefix, sysinfo_prefix_len

global render_frame

section .text

; render_frame - render full frame to output buffer
; For each character position, samples a 4x2 block from the grid
; (with scroll offset and toroidal wrap) and encodes as braille UTF-8
render_frame:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 24                    ; local vars + alignment

    ; Cache dimensions
    mov r14d, [char_rows]
    mov r15d, [char_cols]
    mov eax, [grid_h]
    mov [rsp], eax                 ; [rsp] = H
    mov eax, [grid_w]
    mov [rsp+4], eax               ; [rsp+4] = W
    mov eax, [scroll_oy]
    mov [rsp+8], eax               ; [rsp+8] = oy
    mov eax, [scroll_ox]
    mov [rsp+12], eax              ; [rsp+12] = ox

    ; Reset output buffer (also emits sync-start ESC[?2026h)
    call buf_reset

    ; Write cursor home sequence
    lea rsi, [ansi_home]
    mov ecx, ansi_home_len
    call buf_append

    xor r12d, r12d                 ; r12 = char_row

.row_loop:
    cmp r12d, r14d
    jge .frame_done

    ; Emit ANSI reset at start of each line
    mov rdi, output_buf
    add rdi, [output_pos]
    EMIT_ANSI_RESET
    sub rdi, output_buf
    mov [output_pos], rdi

    mov ebp, -1                    ; prev_heat_idx = -1 (no color set)
    xor r13d, r13d                 ; r13 = char_col

.col_loop:
    cmp r13d, r15d
    jge .row_end

    ; Inline panel injection: at first panel column, emit entire pre-built row
    cmp dword [panel_x], 0
    je .no_panel
    ; Check row in range [panel_y, panel_y+5]
    mov edx, [panel_y]
    cmp r12d, edx
    jl .no_panel
    add edx, 6
    cmp r12d, edx
    jge .no_panel
    ; Check col == panel_x - 1 (0-based trigger point)
    mov edx, [panel_x]
    dec edx
    cmp r13d, edx
    jne .no_panel

    ; === Inject panel row inline ===
    mov rdi, output_buf
    add rdi, [output_pos]

    ; Reset GoL color
    EMIT_ANSI_RESET

    ; Set panel dim color
    lea rsi, [sysinfo_prefix]
    mov ecx, [sysinfo_prefix_len]
    rep movsb

    ; Copy pre-built panel row data
    mov edx, r12d
    sub edx, [panel_y]            ; row_idx (0-5)
    lea rax, [panel_row_off]
    mov eax, [rax + rdx*4]        ; byte offset in panel_buf
    lea rsi, [panel_buf]
    add rsi, rax
    lea rax, [panel_row_len]
    mov ecx, [rax + rdx*4]        ; byte length
    rep movsb

    ; Reset color after panel
    EMIT_ANSI_RESET

    ; Update output_pos
    sub rdi, output_buf
    mov [output_pos], rdi

    ; Reset color tracking, advance col past panel
    mov ebp, -1
    mov edx, [panel_x]
    dec edx
    add edx, [panel_w]
    mov r13d, edx
    jmp .col_loop

.no_panel:

    ; Compute base_row = char_row * 4 + oy
    mov eax, r12d
    shl eax, 2
    add eax, [rsp+8]              ; + oy

    ; Compute base_col = char_col * 2 + ox
    mov ecx, r13d
    shl ecx, 1
    add ecx, [rsp+12]             ; + ox

    ; eax = base_row, ecx = base_col
    ; Build braille value (bl) and max heat (bh)
    xor ebx, ebx                  ; bl = braille_val, bh = max_heat

    ; We need to sample 8 cells: 4 rows x 2 cols
    ; For each cell: wrap row and col, compute offset, read grid+heat

    ; Macro-like inline for each of the 8 cells:
    ; Visibility = grid[cell] OR (heat[cell] > 0)  (shows decay trail)

    ; Row 0, Col 0 -> bit 0x01
    mov edx, eax                   ; row = base_row + 0
    mov esi, ecx                   ; col = base_col + 0
    call .sample_cell              ; returns: dl=grid val, dh=heat val
    test dl, dl
    jnz .r0c0_set
    test dh, dh
    jz .r0c0_skip
.r0c0_set:
    or bl, 0x01
.r0c0_skip:
    cmp dh, bh
    jbe .r0c1
    mov bh, dh
.r0c1:
    ; Row 0, Col 1 -> bit 0x08
    mov edx, eax
    lea esi, [ecx + 1]
    call .sample_cell
    test dl, dl
    jnz .r0c1_set
    test dh, dh
    jz .r0c1_skip
.r0c1_set:
    or bl, 0x08
.r0c1_skip:
    cmp dh, bh
    jbe .r1c0
    mov bh, dh
.r1c0:
    ; Row 1, Col 0 -> bit 0x02
    lea edx, [eax + 1]
    mov esi, ecx
    call .sample_cell
    test dl, dl
    jnz .r1c0_set
    test dh, dh
    jz .r1c0_skip
.r1c0_set:
    or bl, 0x02
.r1c0_skip:
    cmp dh, bh
    jbe .r1c1
    mov bh, dh
.r1c1:
    ; Row 1, Col 1 -> bit 0x10
    lea edx, [eax + 1]
    lea esi, [ecx + 1]
    call .sample_cell
    test dl, dl
    jnz .r1c1_set
    test dh, dh
    jz .r1c1_skip
.r1c1_set:
    or bl, 0x10
.r1c1_skip:
    cmp dh, bh
    jbe .r2c0
    mov bh, dh
.r2c0:
    ; Row 2, Col 0 -> bit 0x04
    lea edx, [eax + 2]
    mov esi, ecx
    call .sample_cell
    test dl, dl
    jnz .r2c0_set
    test dh, dh
    jz .r2c0_skip
.r2c0_set:
    or bl, 0x04
.r2c0_skip:
    cmp dh, bh
    jbe .r2c1
    mov bh, dh
.r2c1:
    ; Row 2, Col 1 -> bit 0x20
    lea edx, [eax + 2]
    lea esi, [ecx + 1]
    call .sample_cell
    test dl, dl
    jnz .r2c1_set
    test dh, dh
    jz .r2c1_skip
.r2c1_set:
    or bl, 0x20
.r2c1_skip:
    cmp dh, bh
    jbe .r3c0
    mov bh, dh
.r3c0:
    ; Row 3, Col 0 -> bit 0x40
    lea edx, [eax + 3]
    mov esi, ecx
    call .sample_cell
    test dl, dl
    jnz .r3c0_set
    test dh, dh
    jz .r3c0_skip
.r3c0_set:
    or bl, 0x40
.r3c0_skip:
    cmp dh, bh
    jbe .r3c1
    mov bh, dh
.r3c1:
    ; Row 3, Col 1 -> bit 0x80
    lea edx, [eax + 3]
    lea esi, [ecx + 1]
    call .sample_cell
    test dl, dl
    jnz .r3c1_set
    test dh, dh
    jz .r3c1_skip
.r3c1_set:
    or bl, 0x80
.r3c1_skip:
    cmp dh, bh
    jbe .emit_char
    mov bh, dh

.emit_char:
    ; bl = braille value, bh = max heat
    mov rdi, output_buf
    add rdi, [output_pos]

    test bl, bl
    jnz .emit_braille

    ; Empty block: reset color if needed, emit space
    cmp ebp, -1
    je .just_space
    ; Emit reset
    EMIT_ANSI_RESET
    mov ebp, -1
.just_space:
    mov byte [rdi], ' '
    inc rdi
    jmp .store_pos

.emit_braille:
    ; Clamp heat
    movzx edx, bh
    cmp edx, MAX_HEAT
    jbe .heat_ok
    mov edx, MAX_HEAT
.heat_ok:
    ; Emit color if different from previous
    cmp edx, ebp
    je .skip_color

    lea rsi, [heat_fg_table]
    mov rsi, [rsi + rdx * 8]      ; ptr to escape string
    lea r8, [heat_fg_lens]
    mov ecx, [r8 + rdx * 4]       ; length
    test ecx, ecx
    jz .skip_color
    push rdx
    rep movsb
    pop rdx
    mov ebp, edx
.skip_color:

    ; Encode braille as UTF-8: U+2800 + bl
    movzx edx, bl
    EMIT_BRAILLE edx

.store_pos:
    sub rdi, output_buf
    mov [output_pos], rdi
    inc r13d
    jmp .col_loop

.row_end:
    ; End of line reset
    mov rdi, output_buf
    add rdi, [output_pos]
    EMIT_ANSI_RESET
    ; Newline (except after last row)
    mov eax, r12d
    inc eax
    cmp eax, r14d
    jge .no_nl
    mov byte [rdi], 10
    inc rdi
.no_nl:
    sub rdi, output_buf
    mov [output_pos], rdi
    inc r12d
    jmp .row_loop

.frame_done:
    add rsp, 24
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; .sample_cell - read grid and heat at wrapped (row, col)
; edx = row (unwrapped), esi = col (unwrapped)
; Returns: dl = grid value, dh = heat value
; Preserves: eax, ecx, ebx, ebp, r8-r15
; Clobbers: edx, esi
;
; Optimization: input values are always in [0, 2*dim-2], so a single
; conditional subtract replaces expensive div instructions.
.sample_cell:
    push rax

    ; Wrap row: if edx >= grid_h, edx -= grid_h
    cmp edx, [grid_h]
    jl .row_ok
    sub edx, [grid_h]
.row_ok:
    ; Wrap col: if esi >= grid_w, esi -= grid_w
    cmp esi, [grid_w]
    jl .col_ok
    sub esi, [grid_w]
.col_ok:
    ; offset = row * W + col
    mov eax, edx
    imul eax, [grid_w]
    add eax, esi

    ; Read both values
    movzx edx, byte [grid + rax]   ; dl = grid val
    mov dh, byte [heat + rax]      ; dh = heat val

    pop rax
    ret
