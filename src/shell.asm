; shell 程序

section shell_header                                ; 外壳程序头部
    length  dq shell_end                            ; #0: 外壳程序的总长度（字节数）
    entry   dq start                                ; #8: 外壳入口点
    linear  dq 0                                    ; #16: 外壳加载的虚拟（线性）地址

section shell_data                                  ; 外壳程序数据段
    shell_msg   db "OS SHELL-"
    time_buff   times 32 db 0

section shell_code                                  ; 外壳程序代码段

%include "./common/user_static64.asm"

    bits 64 

main:
    ; 以下下运行三个程序
    mov r8, 100                                     ; LBA 为 100 的位置
    mov rax, 3                                      ; 创建进程
    syscall
    syscall
    syscall                                         

    mov rax, 0                                      ; 可用行号, dh=行号
    syscall                 
    mov dl, 0
    mov r9b, 0x5f 

    mov r12 [rel linear]

_time:
    lea rbx, [r12 + time_buff]
    mov rax, 1                                      ; 返回当前时间
    syscall 

    lea rbx, [r12, shell_msg]
    mov rax, 2                                      ; 打印字符串, 刚获取的时间字符串也会被打印
    syscall

    jmp _time

start:
    call main 


shell_end: