; 用户程序

section app_header                              ; 应用程序头部
    length  dq app_end                          ; #0：用户程序的总长度（字节数）
    entry   dq start                            ; #8：用户程序入口点
    linear  dq 0                                ; #16：用户程序加载的虚拟（线性）地址

section app_data                                ; 应用程序数据段
    app_msg     times 128 db 0                  ; 应用程序消息缓冲区
    pid_prex    db "Process ID:", 0             ; 进程标识符前缀文本
    pid         times 32 db 0                   ; 进程标识符的文本
    delim       db " doing 1+2+3+...+", 0       ; 分隔文本
    addend      times 32 db 0                   ; 加数的文本
    equal       db "=", 0                       ; 等于号
    cusum       times 32 db 0                   ; 相加结果的文本

section app_code                                ; 应用程序代码段

%include "./common/user_static64.asm"

    bits 64

main:
    mov rax, 0                                  ; 确定当前程序可以使用的显示行, dh=行号
    syscall  

    mov dl, 0
    mov r9b, 0x0f

    mov r12, [rel linear]                       ; 当前程序加载的起始线性地址
    mov rax, 4                                  ; 获取当前进程标识
    syscall 
    mov r8, rax 
    lea rbx, [r12 + pid]
    call bin64_to_dec                           ; 将进程标识转为字符串

    mov r8, 0                                   ; r8 存放累加和
    mov r10, 1                                  ; r10 存放加数

.cusum:
    add r8, r10 
    lea rbx, [r12 + cusum]
    call bin64_to_dec                           ; 本次相加的结果转为字符串
    xchg r8, r10 
    lea rbx, [r12 + addend]
    call bin64_to_dec                           ; 将本次加数转为字符串
    xchg r8, r10 

    lea rdi, [r12 + app_msg]                    ; 清空缓冲区
    mov byte [rdi], 0

    ; 链接字符串, 填入 app_msg 中
    lea rsi, [r12 + pid_prex]
    call string_concatenates 
    lea rsi, [r12 + pid]
    call string_concatenates
    lea rsi, [r12 + delim]
    call string_concatenates
    lea rsi, [r12 + addend]
    call string_concatenates
    lea rsi, [r12 + equal]
    call string_concatenates
    lea rsi, [r12 + cusum]
    call string_concatenates

    mov rbx, rdi                                ; 显示字符串
    mov rax, 2  
    syscall

    inc r10 
    cmp r10, 100000
    jle .cusum

    ret 

start:
    ; 初始化代码...

    call main

    ; 清理, 收尾代码

    mov rax, 5                                  ; 终止任务
    syscall

app_end: