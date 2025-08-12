; shell 程序

section shell_header                                ; 外壳程序头部
    length  dq shell_end                            ; #0: 外壳程序的总长度（字节数）
    entry   dq start                                ; #8: 外壳入口点
    linear  dq 0                                    ; #16: 外壳加载的虚拟（线性）地址

section shell_data                                  ; 外壳程序数据段
    shell_msg   times 128 db 0

    msg0        db "OS SHELL on CPU ", 0
    pcpu        times 32 db 0                       ; 处理器编号的文本
    msg1        db " -", 0

    time_buff    times 32 db 0                      ; 当前时间的文本

section shell_code                                  ; 外壳程序代码段

%include "./common/user_static64.asm"

    bits 64 

main: 
    ; 以下运行 8 个程序
    mov r8, 100                                     ; LBA 为 100 的位置
    mov rax, 3                                      ; 创建进程
    syscall
    syscall
    syscall      
    syscall
    syscall
    syscall
    syscall
    syscall
                          
    mov rax, 0                                      ; 可用行号, dh=行号
    syscall                 
    mov dl, 0
    mov r9b, 0x5f 

    mov r12, [rel linear]

_time:
    lea rbx, [r12 + time_buff]
    mov rax, 1                                      ; 返回当前时间
    syscall 

    mov rax, 6                                      ; 获取当前处理器编号
    syscall
    mov r8, rax 
    lea rbx, [r12 + pcpu]
    call bin64_to_dec

    lea rdi, [r12 + shell_msg]
    mov byte [rdi], 0

    lea rsi, [r12 + msg0]
    call string_concatenates

    lea rsi, [r12 + pcpu]
    call string_concatenates

    lea rsi, [r12 + msg1]
    call string_concatenates

    lea rsi, [r12 + time_buff]
    call string_concatenates

    mov rbx, rdi 
    mov rax, 2                                      ; 打印字符串
    syscall

    jmp _time

start:
    call main 


shell_end: