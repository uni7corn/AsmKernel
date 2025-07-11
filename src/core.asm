; 内核

%include "../common/global_defs.asm"

SECTION core_header                                 ; 内核头部
    length      dd core_end                         ; 内核总长度
    init_entry  dd init                             ; 内核入口点
    position    dq 0                                ; 内核加载虚拟地址

SECTION core_data                                   ; 内核数据段
    welcome     db "Executing in 64-bit mode.", 0x0d, 0x0a, 0   

SECTION core_code                                   ; 内核代码段

%include "../common/core_utils64.asm"

    bits 64

general_interrupt_handler:                          ; 通用中断处理
    iretq

general_exception_handler:                          ; 通用异常处理
    mov r15, [rel position]                         ; 在 24 行 0 列显示红底白字的错误信息
    lea rbx, [r15 + exceptm]
    mov dh, 24
    mov dl, 0
    mov r9b, 0x4f 
    call put_cstringxy64                            ; 在 core_utils64.asm 中实现

    cli 
    hlt                                             ; 停机且不接受外部硬件中断

exceptm         db "A exception raised,halt.", 0    ; 发生异常时的错误信息

init: 
    ; 初始化内核工作环境

    ; 将 GDT 的线性地址映射到虚拟内存高端的相同位置。
    ; 处理器不支持 64 位立即数到内存地址的操作，所以用两条指令完成。
    mov rax, UPPER_GDT_LINEAR                       ; GDT 高端线性地址
    mov qword [SDA_PHY_ADDR + 4], rax

    lgdt [SDA_PHY_ADDR + 2]                

    ; 将栈映射到高端
    ; 64 位模式下不支持源操作数为 64 位立即数的加法操作。
    mov rax, UPPER_LINEAR_START
    add rsp, rax 

    ; 准备让处理器从虚拟地址空间的高端开始执行（现在依然在低端执行）
    mov rax, UPPER_LINEAR_START
    add [rel position], rax                         ; 更新 position 处地址, 采用相对寻址方式
    mov rax, [rel position]
    add eax, .to_upper
    jmp rax                                         ; 用 jmp 改变 rip

.to_upper:
    ; 接下来初始化中断描述符表 IDT，并为 32 个异常以及 224 个中断安装门描述符

    ; 为 32 个异常创建通用处理过程的中断门
    mov r9, [rel position]
    lea rax, [r9 + general_exception_handler]
    call make_interrupt_gate                        ; 

.to_upper:


core_end:
