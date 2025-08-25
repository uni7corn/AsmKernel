; 演示数据竞争和锁定的原子操作 

section app_header                                      ; 应用程序头部
    length      dq app_end                              ; #0：用户程序的总长度（字节数）
    entry       dq start                                ; #8：用户程序入口点
    linear      dq 0                                    ; #16：用户程序加载的虚拟（线性）地址

section app_data                                        ; 应用程序数据段

    tid_prex    db "Thread ", 0
    thrd_msg    db " has completed the calculation.", 0
    share_d     dq 0

section app_code                                        ; 应用程序代码段

%include "./common/user_static64.asm"

    [bits 64]

thread_procedure1:
    mov rbp, rsp                                        ; rbp 访问栈中数据, 高级语言中的局部变量
    sub rsp, 32

    mov rax, 10                                         ; 分配内存
    mov rdx, 160                                        ; 160 个字节
    syscall

    mov [rbp - 8], r13                                  ; rbp-8->字符串缓冲区的线性地址

    add r13, 128
    mov [rbp - 16], r13                                 ; rbp-16->用来保存线程标识的文本

    mov rax, 8                                          ; 获得当前线程的标识
    syscall
    mov r8, rax 
    mov rbx, [rbp - 16]
    call bin64_to_dec

    mov rcx, 500000000

.plus_one:
    lock inc qword [rel share_d]
    loop .plus_one

    mov r12, [rel linear]

    mov rdi, [rbp - 8]                                  ; 缓冲区清零
    mov byte [rdi], 0

    lea rsi, [r12 + tid_prex]
    call string_concatenates

    mov rsi, [rbp - 16]
    call string_concatenates

    lea rsi, [r12 + thrd_msg]
    call string_concatenates

    mov rax, 0                                          ; 当前线程可以使用的显示行
    syscall                                             ; 可用显示行, dh=行号

    mov dl, 0                                           ; 列坐标
    mov r9b, 0x0f                                       ; 文本颜色

    mov rax, 2                                          ; 在指定坐标显示字符串
    mov rbx, rdi 
    syscall

    mov rsp, rbp                                        ; 栈平衡到返回位置
    ret 

thread_procedure2:
    mov rbp, rsp                                        ; rbp 访问栈中数据, 高级语言中的局部变量
    sub rsp, 32

    mov rax, 10                                         ; 分配内存
    mov rdx, 160                                        ; 160 个字节
    syscall

    mov [rbp - 8], r13                                  ; rbp-8->字符串缓冲区的线性地址

    add r13, 128
    mov [rbp - 16], r13                                 ; rbp-16->用来保存线程标识的文本

    mov rax, 8                                          ; 获得当前线程的标识
    syscall
    mov r8, rax 
    mov rbx, [rbp - 16]
    call bin64_to_dec

    mov rcx, 500000000

.minus_one:
    lock dec qword [rel share_d]
    loop .minus_one

    mov r12, [rel linear]

    mov rdi, [rbp - 8]                                  ; 缓冲区清零
    mov byte [rdi], 0

    lea rsi, [r12 + tid_prex]
    call string_concatenates

    mov rsi, [rbp - 16]
    call string_concatenates

    lea rsi, [r12 + thrd_msg]
    call string_concatenates

    mov rax, 0                                          ; 当前线程可以使用的显示行
    syscall                                             ; 可用显示行, dh=行号

    mov dl, 0                                           ; 列坐标
    mov r9b, 0x0f                                       ; 文本颜色

    mov rax, 2                                          ; 在指定坐标显示字符串
    mov rbx, rdi 
    syscall

    mov rsp, rbp                                        ; 栈平衡到返回位置
    ret 

main:
    mov rdi, [rel linear]             

    mov rax, 7                                          ; 创建线程

    lea rsi, [rdi + thread_procedure1]                  ; 线程例程的线性地址
    syscall 
    mov [rel .thrd_1], rdx                              ; 保存线程 1 的标识

    lea rsi, [rdi + thread_procedure2]                  ; 线程例程的线性地址
    syscall 
    mov [rel .thrd_2], rdx                              ; 保存线程 2 的标识

    mov rax, 11
    mov rdx, [rel .thrd_1]                              ; 等待线程 1 结束
    syscall
    mov rdx, [rel .thrd_2]                              ; 等待线程 2 结束
    syscall

    mov r12, [rel linear]

    lea rdi, [r12 + .main_buf]                          ; 字符串缓冲区清零
    mov byte [rdi], 0

    lea rsi, [r12 + .main_msg]
    call string_concatenates

    mov r8, [rel share_d]                               ; 共享变量
    lea rbx, [r12 + .main_dat]
    call bin64_to_dec

    mov rsi, rbx 
    call string_concatenates

    mov rax, 0                                          ; 当前线程可以使用的显示行
    syscall                                             ; 可用显示行, dh=行号

    mov dl, 0                                           ; 列坐标
    mov r9b, 0x0f                                       ; 文本颜色

    mov rax, 2                                          ; 在指定坐标显示字符串
    mov rbx, rdi 
    syscall

    ret 

    .thrd_1     dq 0                                    ; 线程1的标识
    .thrd_2     dq 0                                    ; 线程2的标识

    .main_msg   db "The result after calculation by two threads is:", 0
    .main_dat   times 32 db 0
    .main_buf   times 128 db 0

start:
    ; 初始化代码...

    call main

    ; 清理, 收尾代码

    mov rax, 5                                  ; 终止任务
    syscall

app_end: