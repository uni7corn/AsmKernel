; 用户程序

section app_header                              ; 应用程序头部
    length  dq app_end                          ; #0：用户程序的总长度（字节数）
    entry   dq start                            ; #8：用户程序入口点
    linear  dq 0                                ; #16：用户程序加载的虚拟（线性）地址

section app_data                                ; 应用程序数据段
    tid_prex    db "Thread ", 0                 ; 线程标识前缀文本
    pid_prex    db " <Task ", 0                 ; 进程标识前缀文本
    cpu_prex    db "> on CPU ", 0               ; 处理器标识的前缀文本
    delim       db " do 1+2+3+...+", 0          ; 分隔文本
    equal       db "=", 0                       ; 等于号

section app_code                                ; 应用程序代码段

%include "./common/user_static64.asm"

    bits 64

thread_procedure:
    mov rbp, rsp                                ; rbp 访问栈中数据，高级语言中的局部变量
    sub rsp, 56                                 ; 呐, 这个就叫专业

    mov rax, 10                                 ; 分配内存
    mov rdx, 288                                ; 字节数
    syscall
    mov [rbp - 8], r13                          ; rbp-8->总字符串缓冲区的线性地址

    add r13, 128
    mov [rbp - 16], r13                         ; rbp-16->用来保存线程标识的文本

    add r13, 32
    mov [rbp - 24], r13                         ; rbp-24->用来保存任务标识的文本

    add r13, 32
    mov [rbp - 32], r13                         ; rbp-32->用来保存处理器编号的文本

    add r13, 32
    mov [rbp - 40], r13                         ; rbp-40->用来保存加数的文本

    add r13, 32
    mov [rbp - 48], r13                         ; rbp-48->用来保存累加和的文本

    mov rax, 8                                  ; 获取当前线程标识
    syscall
    mov r8, rax
    mov rbx, [rbp - 16] 
    call bin64_to_dec

    mov rax, 4                                  ; 获取当前进程标识
    syscall
    mov r8, rax
    mov rbx, [rbp - 24] 
    call bin64_to_dec

    mov r12, [rel linear]

    mov rax, 0                                  ; 获取当前程序可使用的显示行
    syscall

    mov dl, 0
    mov r9b, 0x0f 

    mov r8, 0                                   ; r8 存放累加和
    mov r10, 1                                  ; r10 存放加数

.cusum:
    add r8, r10 
    mov rbx, [rbp - 48]
    call bin64_to_dec                           ; 本次相加的结果转为字符串

    xchg r8, r10 

    mov rbx, [rbp - 40]
    call bin64_to_dec                           ; 将本次加数转为字符串

    xchg r8, r10 

    mov rax, 6                                  ; 获取处理器编号
    syscall

    push r8 
    mov r8, rax 
    mov rbx, [rbp - 32]
    call bin64_to_dec
    pop r8 

    mov rdi, [rbp - 8]                          ; 清空缓冲区
    mov byte [rdi], 0

    ; 链接字符串, 填入 app_msg 中
    lea rsi, [r12 + tid_prex]
    call string_concatenates 

    mov rsi, [rbp - 16]
    call string_concatenates

    lea rsi, [r12 + pid_prex]
    call string_concatenates

    mov rsi, [rbp - 24]
    call string_concatenates

    lea rsi, [r12 + cpu_prex]
    call string_concatenates

    mov rsi, [rbp - 32]
    call string_concatenates

    lea rsi, [r12 + delim]
    call string_concatenates

    mov rsi, [rbp - 40]
    call string_concatenates

    lea rsi, [r12 + equal]
    call string_concatenates

    mov rsi, [rbp - 48]
    call string_concatenates

    mov rbx, rdi                                ; 显示字符串
    mov rax, 2  
    syscall

    inc r10 
    cmp r10, 10000
    jle .cusum

    mov rsp, rbp                                ; 平衡栈

    ret 

main:
    mov rsi, [rel linear]

    lea rsi, [rsi + thread_procedure]
    mov rax, 7
    syscall
    syscall

    call thread_procedure

    ret 

start:
    ; 初始化代码...

    call main

    ; 清理, 收尾代码

    mov rax, 5                                  ; 终止任务
    syscall

app_end: