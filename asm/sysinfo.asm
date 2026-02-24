; sysinfo.asm - CPU & RAM floating panel with bar charts
; Pre-builds panel rows into panel_buf for inline injection by render_frame
; Uses ╌ (U+254C) dashed borders

BITS 64
DEFAULT REL

%include "constants.inc"

; --- Imports ---
extern char_cols, char_rows
extern sysinfo_enabled
extern proc_buf, panel_buf
extern cpu_prev_idle, cpu_prev_total
extern cpu_pct, mem_used_mb, mem_total_mb
extern proc_stat_path, proc_meminfo_path
extern cpu_history, ram_history
extern history_pos, history_count, update_counter
extern panel_x, panel_y, panel_w
extern panel_row_off, panel_row_len
extern panel_pos_counter, panel_at_top

; --- Exports ---
global sysinfo_init, sysinfo_update, sysinfo_render

section .text

; =====================================================================
; sysinfo_init - parse argv for --no-sysinfo flag
; =====================================================================
sysinfo_init:
    cmp edi, 2
    jl .done
    mov rdi, [rsi+8]
    lea rsi, [rel no_sysinfo_str]
.cmp_loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .done
    test al, al
    jz .matched
    inc rdi
    inc rsi
    jmp .cmp_loop
.matched:
    mov dword [sysinfo_enabled], 0
.done:
    ret

; =====================================================================
; sysinfo_update - throttled read of /proc/stat and /proc/meminfo
; =====================================================================
sysinfo_update:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov eax, [update_counter]
    inc eax
    mov [update_counter], eax
    cmp eax, 20
    jl .done
    mov dword [update_counter], 0

    ; --- CPU from /proc/stat ---
    lea rdi, [rel proc_stat_path]
    mov esi, O_RDONLY
    mov eax, SYS_open
    syscall
    test eax, eax
    js .cpu_done
    mov r12d, eax

    mov edi, r12d
    lea rsi, [rel proc_buf]
    mov edx, 1023
    mov eax, SYS_read
    syscall
    mov r13, rax

    mov edi, r12d
    mov eax, SYS_close
    syscall

    cmp r13, 0
    jle .cpu_done

    lea rdi, [rel proc_buf]
    mov byte [rdi + r13], 0

    lea rsi, [rel proc_buf]
.skip_prefix:
    lodsb
    cmp al, ' '
    jne .skip_prefix
.skip_spaces0:
    cmp byte [rsi], ' '
    jne .parse_fields
    inc rsi
    jmp .skip_spaces0

.parse_fields:
    xor r14, r14
    xor r15, r15
    xor ecx, ecx

.next_field:
    cmp ecx, 7
    jge .calc_cpu
    call parse_uint
    add r14, rax
    cmp ecx, 3
    jne .not_idle
    mov r15, rax
.not_idle:
    inc ecx
.skip_sp:
    cmp byte [rsi], ' '
    jne .check_nl
    inc rsi
    jmp .skip_sp
.check_nl:
    cmp byte [rsi], 10
    je .calc_cpu
    cmp byte [rsi], 0
    je .calc_cpu
    jmp .next_field

.calc_cpu:
    mov rax, r14
    sub rax, [cpu_prev_total]
    mov rbx, r15
    sub rbx, [cpu_prev_idle]
    mov [cpu_prev_total], r14
    mov [cpu_prev_idle], r15
    test rax, rax
    jz .cpu_done
    mov rcx, rax
    sub rax, rbx
    imul rax, 100
    xor edx, edx
    div rcx
    cmp eax, 100
    jle .store_cpu
    mov eax, 100
.store_cpu:
    mov [cpu_pct], eax

.cpu_done:
    ; --- RAM from /proc/meminfo ---
    lea rdi, [rel proc_meminfo_path]
    mov esi, O_RDONLY
    mov eax, SYS_open
    syscall
    test eax, eax
    js .ram_done
    mov r12d, eax

    lea rsi, [rel proc_buf]
    mov edx, 1023
    mov edi, r12d
    mov eax, SYS_read
    syscall
    mov r13, rax

    mov edi, r12d
    mov eax, SYS_close
    syscall

    cmp r13, 0
    jle .ram_done

    lea rdi, [rel proc_buf]
    mov byte [rdi + r13], 0

    lea rsi, [rel proc_buf]
    lea rdi, [rel memtotal_tag]
    mov ecx, 9
    call find_memfield
    test rax, rax
    jz .ram_done
    xor edx, edx
    mov ecx, 1024
    div ecx
    mov [mem_total_mb], eax
    mov r14d, eax

    lea rsi, [rel proc_buf]
    lea rdi, [rel memavail_tag]
    mov ecx, 13
    call find_memfield
    test rax, rax
    jz .ram_done
    xor edx, edx
    mov ecx, 1024
    div ecx
    mov ecx, r14d
    sub ecx, eax
    mov [mem_used_mb], ecx

.ram_done:
    ; --- Push to history ring buffers ---
    mov ecx, [history_pos]

    mov eax, [cpu_pct]
    lea rsi, [rel cpu_history]
    mov [rsi + rcx], al

    mov eax, [mem_used_mb]
    imul eax, 100
    mov ebx, [mem_total_mb]
    test ebx, ebx
    jz .no_ram_hist
    xor edx, edx
    div ebx
    cmp eax, 100
    jle .ram_pct_ok
    mov eax, 100
.ram_pct_ok:
    lea rsi, [rel ram_history]
    mov [rsi + rcx], al
.no_ram_hist:

    inc ecx
    and ecx, 127
    mov [history_pos], ecx

    mov eax, [history_count]
    cmp eax, 128
    jge .done
    inc eax
    mov [history_count], eax

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; =====================================================================
; sysinfo_render - pre-build panel rows into panel_buf
; Called BEFORE render_frame. Does NOT write to output_buf.
; render_frame injects panel_buf data inline for flicker-free rendering.
;
; Stack locals (rbp-relative):
;   [rbp-4]   box_w
;   [rbp-8]   box_x
;   [rbp-12]  box_y
;   [rbp-16]  half_w
;   [rbp-20]  num_disp
;   [rbp-24]  start_idx
;   [rbp-28]  pad_cols
;   [rbp-32]  cpu_tlen
;   [rbp-36]  ram_tlen
;   [rbp-68]  cpu_title  (32 bytes)
;   [rbp-100] ram_title  (32 bytes)
;   [rbp-104] cur_row
; =====================================================================
sysinfo_render:
    cmp dword [sysinfo_enabled], 0
    je .ret_early

    mov eax, [char_rows]
    cmp eax, 8
    jl .ret_early

    mov eax, [char_cols]
    cmp eax, 30
    jl .ret_early

    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbp, rsp
    sub rsp, 112

    ; --- Compute box dimensions ---
    mov eax, [char_cols]
    imul eax, 60
    xor edx, edx
    mov ecx, 100
    div ecx
    cmp eax, 30
    jge .bw_ok
    mov eax, 30
.bw_ok:
    cmp eax, [char_cols]
    jle .bw_ok2
    mov eax, [char_cols]
.bw_ok2:
    or eax, 1                     ; force odd: box_w = 2*half_w + 1
    mov [rbp-4], eax

    mov ecx, [char_cols]
    sub ecx, eax
    shr ecx, 1
    inc ecx
    mov [rbp-8], ecx              ; box_x (1-based)

    ; Toggle panel position every 400 frames (~60 seconds)
    mov eax, [panel_pos_counter]
    inc eax
    cmp eax, 400
    jl .no_toggle
    xor eax, eax
    xor ecx, ecx
    cmp dword [panel_at_top], 0
    sete cl                        ; toggle: 0→1, 1→0
    mov [panel_at_top], ecx
.no_toggle:
    mov [panel_pos_counter], eax

    ; box_y: top = 1, bottom = char_rows - 7
    cmp dword [panel_at_top], 0
    jne .pos_top
    mov eax, [char_rows]
    sub eax, 7
    jmp .pos_done
.pos_top:
    mov eax, 1
.pos_done:
    mov [rbp-12], eax             ; box_y

    ; Export panel geometry
    mov eax, [rbp-8]
    mov [panel_x], eax
    mov eax, [rbp-12]
    mov [panel_y], eax
    mov eax, [rbp-4]
    mov [panel_w], eax

    ; half_w = (box_w - 1) / 2
    mov eax, [rbp-4]
    dec eax
    shr eax, 1
    mov [rbp-16], eax

    ; num_disp = min(history_count, half_w)
    mov ecx, [history_count]
    cmp ecx, eax
    jle .nd_ok
    mov ecx, eax
.nd_ok:
    mov [rbp-20], ecx

    ; start_idx = (history_pos - num_disp + 128) & 127
    mov eax, [history_pos]
    sub eax, ecx
    add eax, 128
    and eax, 127
    mov [rbp-24], eax

    ; pad_cols = half_w - num_disp
    mov eax, [rbp-16]
    sub eax, ecx
    mov [rbp-28], eax

    ; --- Format CPU title: " CPU: XX% " ---
    lea rdi, [rbp-68]
    mov byte [rdi],   ' '
    mov byte [rdi+1], 'C'
    mov byte [rdi+2], 'P'
    mov byte [rdi+3], 'U'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    add rdi, 6
    mov eax, [cpu_pct]
    call uint_to_str
    add rdi, rcx
    mov byte [rdi],   '%'
    mov byte [rdi+1], ' '
    add rdi, 2
    lea rax, [rbp-68]
    sub rdi, rax
    mov [rbp-32], edi

    ; --- Format RAM title: " RAM: XX% X.X/X.XG " ---
    lea rdi, [rbp-100]
    mov byte [rdi],   ' '
    mov byte [rdi+1], 'R'
    mov byte [rdi+2], 'A'
    mov byte [rdi+3], 'M'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    add rdi, 6

    ; ram percentage
    mov eax, [mem_used_mb]
    imul eax, 100
    mov ecx, [mem_total_mb]
    test ecx, ecx
    jz .ram_zero_pct
    xor edx, edx
    div ecx
    cmp eax, 100
    jle .ram_emit_pct
    mov eax, 100
    jmp .ram_emit_pct
.ram_zero_pct:
    xor eax, eax
.ram_emit_pct:
    call uint_to_str
    add rdi, rcx
    mov byte [rdi],   '%'
    mov byte [rdi+1], ' '
    add rdi, 2

    ; used GB
    mov eax, [mem_used_mb]
    imul eax, 10
    add eax, 512
    xor edx, edx
    mov ecx, 1024
    div ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    push rdx
    call uint_to_str
    add rdi, rcx
    mov byte [rdi], '.'
    inc rdi
    pop rax
    add al, '0'
    mov [rdi], al
    inc rdi

    mov byte [rdi], '/'
    inc rdi

    ; total GB
    mov eax, [mem_total_mb]
    imul eax, 10
    add eax, 512
    xor edx, edx
    mov ecx, 1024
    div ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    push rdx
    call uint_to_str
    add rdi, rcx
    mov byte [rdi], '.'
    inc rdi
    pop rax
    add al, '0'
    mov [rdi], al
    inc rdi

    mov byte [rdi],   'G'
    mov byte [rdi+1], ' '
    add rdi, 2

    lea rax, [rbp-100]
    sub rdi, rax
    mov [rbp-36], edi

    ; === Pre-build panel rows into panel_buf ===
    lea rdi, [rel panel_buf]
    mov r12, rdi                   ; base pointer for offset calculations

    ; --- Row 0: Top dashed border with titles ---
    ; Record offset
    mov rax, rdi
    sub rax, r12
    lea rcx, [rel panel_row_off]
    mov [rcx], eax

    ; Left half: title then ╌ to fill half_w
    mov ecx, [rbp-32]
    cmp ecx, [rbp-16]
    jle .r0_cpu_ok
    mov ecx, [rbp-16]
.r0_cpu_ok:
    mov r13d, ecx                  ; save title chars used
    lea rsi, [rbp-68]
    rep movsb
    mov eax, [rbp-16]
    sub eax, r13d
    mov ecx, eax
    call emit_dashes

    ; Center gap: ╌
    mov byte [rdi], 0xE2
    mov byte [rdi+1], 0x95
    mov byte [rdi+2], 0x8C
    add rdi, 3

    ; Right half: title then ╌ to fill half_w
    mov ecx, [rbp-36]
    cmp ecx, [rbp-16]
    jle .r0_ram_ok
    mov ecx, [rbp-16]
.r0_ram_ok:
    mov r13d, ecx
    lea rsi, [rbp-100]
    rep movsb
    mov eax, [rbp-16]
    sub eax, r13d
    mov ecx, eax
    call emit_dashes

    ; Record row 0 length
    mov rax, rdi
    sub rax, r12
    lea rcx, [rel panel_row_off]
    sub eax, [rcx]
    lea rcx, [rel panel_row_len]
    mov [rcx], eax

    ; --- Rows 1-4: Content rows ---
    mov dword [rbp-104], 0

.prebuild_content:
    cmp dword [rbp-104], 4
    jge .prebuild_bottom

    ; Record row offset (row_idx = content_row + 1)
    mov edx, [rbp-104]
    inc edx
    mov rax, rdi
    sub rax, r12
    lea rcx, [rel panel_row_off]
    mov [rcx + rdx*4], eax

    ; CPU bars
    lea r9, [rel cpu_colors]
    lea r11, [rel cpu_history]
    call emit_history_section

    ; Center gap
    mov byte [rdi], ' '
    inc rdi

    ; RAM bars
    lea r9, [rel ram_colors]
    lea r11, [rel ram_history]
    call emit_history_section

    ; Record row length
    mov edx, [rbp-104]
    inc edx
    mov rax, rdi
    sub rax, r12
    lea rcx, [rel panel_row_off]
    sub eax, [rcx + rdx*4]
    lea rcx, [rel panel_row_len]
    mov [rcx + rdx*4], eax

    inc dword [rbp-104]
    jmp .prebuild_content

.prebuild_bottom:
    ; --- Row 5: Bottom dashed border ---
    mov rax, rdi
    sub rax, r12
    lea rcx, [rel panel_row_off]
    mov [rcx + 5*4], eax

    mov ecx, [rbp-4]              ; box_w ╌ chars
    call emit_dashes

    mov rax, rdi
    sub rax, r12
    lea rcx, [rel panel_row_off]
    sub eax, [rcx + 5*4]
    lea rcx, [rel panel_row_len]
    mov [rcx + 5*4], eax

    ; Done
    add rsp, 112
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.ret_early:
    ret

; =====================================================================
; emit_history_section - emit padded bar chart section at [rdi]
; Input: r9 = color table, r11 = history array ptr
; Uses rbp-relative locals: [rbp-28]=pad, [rbp-20]=num_disp,
;   [rbp-24]=start_idx, [rbp-104]=content_row
; Clobbers: rax, rbx, ecx, edx, rsi, r8, r10 (via emit_bar_cell_colored)
; =====================================================================
emit_history_section:
    push rbx
    ; Pad spaces
    mov ecx, [rbp-28]
.ehs_pad:
    test ecx, ecx
    jz .ehs_bars
    mov byte [rdi], ' '
    inc rdi
    dec ecx
    jmp .ehs_pad
.ehs_bars:
    xor ebx, ebx
.ehs_loop:
    cmp ebx, [rbp-20]
    jge .ehs_done
    mov eax, [rbp-24]
    add eax, ebx
    and eax, 127
    movzx eax, byte [r11 + rax]
    mov ecx, [rbp-104]
    call emit_bar_cell_colored
    inc ebx
    jmp .ehs_loop
.ehs_done:
    pop rbx
    ret

; =====================================================================
; emit_dashes - emit ecx ╌ (U+254C, light double dash) at [rdi]
; E2 95 8C
; =====================================================================
emit_dashes:
    test ecx, ecx
    jz .dd_done
.dd_loop:
    mov byte [rdi], 0xE2
    mov byte [rdi+1], 0x95
    mov byte [rdi+2], 0x8C
    add rdi, 3
    dec ecx
    jnz .dd_loop
.dd_done:
    ret

; =====================================================================
; emit_bar_cell_colored - emit colored braille bar cell at [rdi]
; Input: eax = value (0-100), ecx = content_row (0-3),
;        r9 = color table ptr (3 entries × 7 bytes)
; Uses braille chars (U+2800+xx) for bars. Both columns lit = wide bar.
; 8 levels per cell (4 dot rows × on/off), 4 cells = 32 levels total.
; Braille dot layout (bottom to top):
;   row3: dots 7+8 = 0xC0
;   row2: dots 3+6 = 0x24
;   row1: dots 2+5 = 0x12
;   row0: dots 1+4 = 0x09
; Clobbers: eax, ecx, edx, r8d, r10d
; =====================================================================
emit_bar_cell_colored:
    mov r10d, eax                  ; save value for color lookup

    ; value_units = value * 32 / 100 (0-32)
    shl eax, 5
    mov r8d, ecx                   ; save content_row
    mov ecx, 100
    xor edx, edx
    div ecx
    ; Ensure at least 1 unit if value > 0
    test eax, eax
    jnz .bcc_has_units
    test r10d, r10d
    jz .bcc_has_units
    mov eax, 1
.bcc_has_units:

    ; threshold = (3 - content_row) * 8
    mov ecx, 3
    sub ecx, r8d
    shl ecx, 3                    ; ecx = threshold (bottom of this cell)

    ; How many dot-rows are filled in this cell (0-8)?
    ; filled = clamp(value_units - threshold, 0, 8)
    sub eax, ecx                   ; eax = value_units - threshold
    cmp eax, 0
    jle .bcc_empty
    cmp eax, 8
    jle .bcc_partial
    mov eax, 8
.bcc_partial:
    ; eax = filled levels (1-8)
    ; Build braille byte: light dot rows from bottom up
    ; level 1-2: row3 (0xC0), 3-4: +row2 (0x24), 5-6: +row1 (0x12), 7-8: +row0 (0x09)
    xor r8d, r8d                   ; braille bits accumulator
    cmp eax, 2
    jl .bcc_r3_half
    or r8d, 0xC0                   ; full row3
    jmp .bcc_check_r2
.bcc_r3_half:
    ; 1 level: just bottom dot of each col = dots 7+8 still both
    or r8d, 0xC0
    jmp .bcc_encode
.bcc_check_r2:
    cmp eax, 4
    jl .bcc_r2_half
    or r8d, 0x24                   ; full row2
    jmp .bcc_check_r1
.bcc_r2_half:
    cmp eax, 3
    jl .bcc_encode
    or r8d, 0x24
    jmp .bcc_encode
.bcc_check_r1:
    cmp eax, 6
    jl .bcc_r1_half
    or r8d, 0x12                   ; full row1
    jmp .bcc_check_r0
.bcc_r1_half:
    cmp eax, 5
    jl .bcc_encode
    or r8d, 0x12
    jmp .bcc_encode
.bcc_check_r0:
    cmp eax, 8
    jl .bcc_r0_half
    or r8d, 0x09                   ; full row0
    jmp .bcc_encode
.bcc_r0_half:
    cmp eax, 7
    jl .bcc_encode
    or r8d, 0x09

.bcc_encode:
    ; Emit color escape
    call .bcc_emit_color

    ; Encode braille as UTF-8
    EMIT_BRAILLE r8d
    ret

.bcc_empty:
    ; Empty braille (U+2800 = blank) - no color needed
    xor r8d, r8d
    EMIT_BRAILLE r8d
    ret

; .bcc_emit_color - emit 7-byte color escape based on r10d (value 0-100)
.bcc_emit_color:
    xor edx, edx
    cmp r10d, 34
    jl .bcc_c
    inc edx
    cmp r10d, 67
    jl .bcc_c
    inc edx
.bcc_c:
    imul edx, 7
    mov cl, [r9 + rdx]
    mov [rdi], cl
    mov cl, [r9 + rdx + 1]
    mov [rdi+1], cl
    mov cl, [r9 + rdx + 2]
    mov [rdi+2], cl
    mov cl, [r9 + rdx + 3]
    mov [rdi+3], cl
    mov cl, [r9 + rdx + 4]
    mov [rdi+4], cl
    mov cl, [r9 + rdx + 5]
    mov [rdi+5], cl
    mov cl, [r9 + rdx + 6]
    mov [rdi+6], cl
    add rdi, 7
    ret

; =====================================================================
; parse_uint - parse ASCII decimal from [rsi]
; =====================================================================
parse_uint:
    xor eax, eax
.loop:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .done
    imul eax, 10
    add eax, edx
    inc rsi
    jmp .loop
.done:
    ret

; =====================================================================
; uint_to_str - convert unsigned integer eax to decimal ASCII at [rdi]
; Returns: ecx = chars written (rdi NOT advanced)
; =====================================================================
uint_to_str:
    push rbx
    push rdi
    mov ebx, eax
    xor ecx, ecx
    mov r8d, 10
.count:
    xor edx, edx
    div r8d
    inc ecx
    test eax, eax
    jnz .count
    mov eax, ebx
    push rcx
    add rdi, rcx
.write:
    dec rdi
    xor edx, edx
    div r8d
    add dl, '0'
    mov [rdi], dl
    test eax, eax
    jnz .write
    pop rcx
    pop rdi
    pop rbx
    ret

; =====================================================================
; find_memfield - find a field in /proc/meminfo and return its value
; Input: rsi = buffer to search, rdi = tag string, ecx = tag length
; Output: eax = parsed value (0 if not found)
; =====================================================================
find_memfield:
    push rbx
    push r12
    mov r12, rdi                   ; tag pointer
    mov ebx, ecx                   ; tag length
.scan:
    cmp byte [rsi], 0
    je .notfound
    ; Try matching tag at current position
    xor ecx, ecx
.cmp:
    cmp ecx, ebx
    jge .matched
    movzx eax, byte [rsi + rcx]
    cmp al, [r12 + rcx]
    jne .next
    inc ecx
    jmp .cmp
.next:
    inc rsi
    jmp .scan
.matched:
    add rsi, rbx                   ; skip past tag
.skip_spaces:
    cmp byte [rsi], ' '
    jne .parse
    inc rsi
    jmp .skip_spaces
.parse:
    call parse_uint
    pop r12
    pop rbx
    ret
.notfound:
    xor eax, eax
    pop r12
    pop rbx
    ret

; --- Read-only data ---
section .rodata

no_sysinfo_str: db '--no-sysinfo', 0
memtotal_tag:   db 'MemTotal:'
memavail_tag:   db 'MemAvailable:'

; Bar color tables (3 entries × 7 bytes each)
; ESC[0;XXm resets dim attribute then sets foreground color
; CPU: green → yellow → bright red
cpu_colors:
    db 27, '[0;32m'            ; green  (0-33%)
    db 27, '[0;33m'            ; yellow (34-66%)
    db 27, '[0;91m'            ; bright red (67-100%)

; RAM: cyan → magenta → bright magenta
ram_colors:
    db 27, '[0;36m'            ; cyan (0-33%)
    db 27, '[0;35m'            ; magenta (34-66%)
    db 27, '[0;95m'            ; bright magenta (67-100%)

; Block chars now inlined in emit_bar_cell_colored (only █ and ▄ used)
