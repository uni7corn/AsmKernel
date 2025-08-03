; 用户通用代码

    bits 64 

; ------------------------------------------------------------
; bin64_to_dec
; 功能: 将二进制数转换为十进制字符串
; 输入: r8=64位二进制数, rbx=目标缓冲区线性地址
; ------------------------------------------------------------
bin64_to_dec: 
    push rax
    push rbx
    push rcx
    push rdx
    push r8

    bt r8, 63                                       ; 检查最高位, 处理正,负数
    jnc .begin
    mov byte [rbx], "-"
    neg r8                                          ; 取反, 将负数转为正数

    inc rbx

.begin:
    mov rax, r8                                     ; rax 是被除数
    mov r8, 10
    xor rcx, rcx                                    ; rcx 是位数

.next_div:
    xor rdx, rdx                                    ; 使用 128 位除法, 要将 rdx 清零
    div r8 
    push rdx                                        ; 保存分解的数位
    inc rcx 
    or rax, rax                                     ; 商为 0?
    jz .rotate
    jmp .next_div

.rotate:
    pop rdx 
    add dl, 0x30                                    ; 将数位转为 ASCII
    mov [rbx], dl 
    inc rbx 
    loop .rotate

    mov byte [rbx], 0

    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret 

; ------------------------------------------------------------
; string_concatenates
; 功能: 将源字符串连接到目的字符串的尾部
; 输入: rsi=源字符串的线性地址, rdi=目的字符串的线性地址
; ------------------------------------------------------------
string_concatenates:
    push rax
    push rsi
    push rdi

    
.r0:                                                ; 先找到 rdi 的结尾
    cmp byte [rdi], 0
    jz .r1 
    inc rdi 
    jmp .r0 
    
.r1:                                                ; 再复制源字符串过去
    mov al, [rsi]
    mov [rdi], al 
    cmp al, 0
    jz .r2 
    inc rsi 
    inc rdi 
    jmp .r1 
    
.r2:
    pop rdi 
    pop rsi 
    pop rax 

    ret 
