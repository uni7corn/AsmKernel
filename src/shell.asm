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
    
    