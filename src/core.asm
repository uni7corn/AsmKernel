; 内核

%include "./common/global_defs.asm"

SECTION core_header                                 ; 内核头部
    length      dd core_end                         ; 内核总长度
    init_entry  dd init                             ; 内核入口点
    position    dq 0                                ; 内核加载虚拟地址

SECTION core_data                                   ; 内核数据段
    welcome     db "Executing in 64-bit mode.", 0x0d, 0x0a, 0   
    tss_ptr     dq 0                                ; 任务状态段 TSS 从此处开始
    sys_entry   dq get_screen_row
                dq get_cmos_time
                dq put_cstringxy64
                dq create_process
                dq get_current_pid
                dq terminate_process
    pcb_ptr     dq 0                                ; 进程控制块 PCB 首节点的线性地址
    cur_pcb     dq 0                                ; 当前任务的 PCB 线性地址    
SECTION core_code                                   ; 内核代码段

%include "./common/core_utils64.asm"

    [bits 64]

; ------------------------------------------------------------
; general_interrupt_handler
; 功能: 通用中断处理
; ------------------------------------------------------------
general_interrupt_handler:
    iretq

; ------------------------------------------------------------
; general_exception_handler
; 功能: 通用异常处理
; ------------------------------------------------------------
general_exception_handler:
    mov r15, [rel position]                         ; 在 24 行 0 列显示红底白字的错误信息
    lea rbx, [r15 + exceptm]
    mov dh, 24
    mov dl, 0
    mov r9b, 0x4f 
    call put_cstringxy64                            ; 在 core_utils64.asm 中实现

    cli 
    hlt                                             ; 停机且不接受外部硬件中断

exceptm         db "A exception raised,halt.", 0    ; 发生异常时的错误信息

; ------------------------------------------------------------
; general_8259ints_handler
; 功能: 通用的 8259 中断处理过程
; ------------------------------------------------------------
general_8259ints_handler:
    push rax 

    mov al, 0x20                                    ; 中断结束命令 EOI
    out 0xa0, al                                    ; 向从片发送
    out 0x20, al                                    ; 向主片发送

    pop rax 

    iretq

; ------------------------------------------------------------
; rtm_interrupt_handle
; 功能: 实时时钟中断处理过程(任务切换)
; ------------------------------------------------------------
rtm_interrupt_handle:
    push r8 
    push rax 
    push rbx 

    mov al, 0x20                                    ; 中断结束命令 EOI
    out 0xa0, al                                    ; 向从片发送
    out 0x20, al                                    ; 向主片发送

    mov al, 0x0c                                    ; 寄存器 c 的索引, 且开放 NMI
    out 0x70, al
    in al, 0x71                                     ; 读一下 RTC 的寄存器C, 否则只发生一次中断, 此处不考虑闹钟和周期性中断的情况

    ; 以下开始执行任务切换
    ; 任务切换的原理是, 它发生在所有任务的全局空间。在任务 A 的全局空间执行任务切换，切换到任务B, 实际上也是从任务B的全局空间返回任务B的私有空间。
; ...

; ------------------------------------------------------------
; create_process
; 功能: 创建新的任务
; 输入: r8=程序的起始逻辑扇区号
; ------------------------------------------------------------
create_process:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; 在内核空间创建任务控制块 PCB, 来记录任务相关信息, 内核通过任务控制块来跟踪和识别任务, 并对任务进行管理和控制
    mov rcx, 512                                    ; 任务控制块 PCB 的尺寸, PCB 的格式见书中 205 图
    call core_memory_allocate                       ; 在内核分配地址

    mov r11, r13                                    ; r11 寄存器用来保存 PCB 线性地址

    mov qword [r11 + 24], USER_ALLOC_START          ; 填写 PCB 的下一次内存分配时可用线性地址
    
    ; 从当前的四级头表复制并创建新任务的四级头表
    call copy_current_pml4                          ; 在 core_utils64.asm 中实现
    mov [r11 + 56], rax                             ; 填写 PCB 的 CR3, 默认 PCD=PWT=0(这两个属性忘记的话可以看看书中 123 页)

    ; 以下，切换到新任务的地址空间，并清空其4级头表的前半部分。
    ; 我们正在地址空间的高端执行，可正常执行内核代码并访问内核数据，同时，当前使用的栈位于地址空间高端的栈。
    mov r15, cr3                                    ; 保存控制寄存器
    mov cr3, rax                                    ; 切换到新四级头表的新地址空间

; ------------------------------------------------------------
; syscall_procedure
; 功能: 系统调用的处理过程
; 注意: RCX 和 R11 由处理器使用, 保存 RIP 和 RFLAGS 的内容; RBP 和 R15 由此例程占用. 如有必要, 请用户程序在调用 syscall 前保存它们, 在系统调用返回后自行恢复.
; ------------------------------------------------------------
syscall_procedure: 
    mov rbp, rsp 
    mov r15, [rel tss_ptr]
    mov rsp, [r15 + 4]                              ; 使用 TSS 的 RSP0 作为安全栈

    sti                                             ; 恢复中断

    mov r15, [rel position]
    add r15, [r15 + rax * 8 + sys_entry]
    call r15

    cli                                             ; 关中断, 恢复栈
    mov rsp, rbp 
    o64 sysret

; ------------------------------------------------------------
; init
; 功能: 初始化内核工作环境
; ------------------------------------------------------------
init: 
    ; 将 GDT 的线性地址映射到虚拟内存高端的相同位置。
    ; 处理器不支持 64 位立即数到内存地址的操作, 所以用两条指令完成。
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
    add rax, .to_upper
    jmp rax                                         ; 用 jmp 改变 rip

.to_upper:
    ; 接下来初始化中断描述符表 IDT，并为 32 个异常以及 224 个中断安装门描述符

    ; 为 32 个异常创建通用处理过程的中断门
    mov r9, [rel position]
    lea rax, [r9 + general_exception_handler]
    call make_interrupt_gate                        ; 在 core_utils64.asm 中实现

    xor r8, r8  
.idt0:                                              ; 32 个异常
    call mount_idt_entry                            ; 在 core_utils64.asm 中实现
    inc r8 
    cmp r8, 31 
    jle .idt0

    ; 创建并安装中断门
    lea rax, [r9 + general_interrupt_handler]       
    call make_interrupt_gate                        ; 在 core_utils64.asm 中实现

    mov r8, 32 
.idt1:
    call mount_idt_entry                            ; 在 core_utils64.asm 中实现
    inc r8 
    cmp r8, 255
    jle .idt1

    mov rax, UPPER_IDT_LINEAR                       ; 中断描述符表 IDT 的高端线性地址
    mov rbx, UPPER_SDA_LINEAR                       ; 系统数据区 SDA 的高端线性地址
    mov word [rbx + 0x0c], 256 * 16 - 1
    mov qword [rbx + 0x0e], rax                     ; 将 IDT 的线性地址和界限写入内核空间保存
    

    lidt [rbx + 0x0c]                               ; 加载 IDT

    call init_8259                                  ; 初始化 8259 中断控制器，包括重新设置中断向量号

    lea rax, [r9 + general_8259ints_handler]        ; 得到通用 8259 中断处理过程的线性地址
    call make_interrupt_gate                        ; 在 core_utils64.asm 中实现

    mov r8, 0x20
.8259:
    call mount_idt_entry                            ; 在 core_utils64.asm 中实现
    inc r8
    cmp r8, 0x2f                                    ; 8259 用来收集外部硬件中断信号, 提供 16 个中断向量, 将之前的覆盖
    jle .8259

    sti                                             ; 开放硬件中断

    ; 在 64 位模式下显示的第一条信息!
    mov r15, [rel position]
    lea rbx, [r15 + welcome]
    call put_string64                               ; 在 core_utils64.asm 中实现

    ; 安装系统服务(syscall, sysret)所需的代码段和栈段描述符
    sub rsp, 16                                     ; 开辟 16 字节空间操作 GDT, GDTR
    sgdt [rsp]
    xor rbx, rbx 
    mov bx, [rsp]                                   ; 得到 GDT 界限值(表的总字节数 - 1 == 下标)
    inc bx
    add rbx, [rsp + 2]                              ; GDT 基址 + GDT 界限值 + 1 == 新描述符的地址
    ; 增加新的描述符, 这里可以看书中 182 页的图, 将之前设置的四个描述符也画全了

    ; 创建 4# 描述符, 栈/数据段描述符, DPL= 0
    mov dword [rbx], 0x0000ffff
    mov dword [rbx + 4], 0x00cf9200                
    ; 创建 5# 描述符, 兼容模式下代码段描述符, 暂不支持, 位置保留, 设为全 0
    mov dword [rbx + 8], 0  
    mov dword [rbx + 12], 0
    ; 创建 6# 描述符, 栈/数据段描述符, DPL= 3
    mov dword [rbx + 16], 0x0000ffff
    mov dword [rbx + 20], 0x00cff200
    ; 创建 7# 描述符, 64 位模式的代码段描述符, DPL= 3
    mov dword [rbx + 24], 0x0000ffff
    mov dword [rbx + 28], 0x00aff800

    ; 安装任务状态段 TSS 的描述符, 见书中 200 页
    mov rcx, 104                                    ; TSS 标准长度
    call core_memory_allocate                       ; 在 core_utils64.asm 中实现
    mov [rel, tss_ptr], r13 
    mov rax, r13 
    call make_tss_descriptor                        ; 在 core_utils64.asm 中实现
    mov qword [rbx + 32], rsi                       ; TSS 描述符低 64 位
    mov qword [rbx + 40], rdi                       ; TSS 描述符高 64 位

    add word [rsp], 48                              ; 四个段描述符和一个 TSS 描述符总字节数
    lgdt [rsp]
    add rsp, 16                                     ; 栈平衡

    mov cx, 0x0040                                  ; TSS 描述符选择子
    ltr cx                                          ; 使用 ltr 指令加载 TSS 选择子

    ; 为快速系统调用 syscall 和 sysret 准备参数
    mov eax, 0x0c0000080                            ; 指定型号专属寄存器 IA32_EFER
    rdmsr
    bts eax, 0                                      ; 置位 SCE 位, 允许 syscall 和 sysret
    wrmsr

    mov ecx, 0xc0000081                             ; IA32_STAR
    mov edx, (RESVD_DESC_SEL << 16) | CORE_CODE64_SEL ; 高 32 位 
    xor eax, eax                                    ; 低 32 位
    wrmsr

    mov ecx, 0xc0000082                             ; IA32_LSTAR
    mov rax, [rel position]
    lea rax, [rax + syscall_procedure]              ; 只用 EAX 部分
    mov rdx, rax 
    shr rdx, 32                                     ; 只用 EDX 部分
    wrmsr

    mov ecx, 0xc0000084                             ; IA32_FMASK
    xor edx, edx 
    mov eax, 0x00047700                             ; 将 TF, IF, DF, IOPL, AC 清零, 其他保持不变, 可看书 185 页的图
    wrmsr

    ; 以下安装用于任务切换的实时时钟中断处理过程
    mov r9, [rel position]
    lea rax, [r9 + rtm_interrupt_handle]            ; 得到中断处理过程的线性地址
    call make_interrupt_gate

    cli 

    mov r8, 0x28                                    ; 使用 0x20 时, 应调整 bochs 的时间速率
    call mount_idt_entry

    ; 设置与时钟中断相关的硬件
    mov al, 0x0b                                    ; RTC 寄存器 B
    or al, 0x80                                     ; 阻断 NMI
    out 0x70, al 

    mov al, 0x12                                    ; 设置寄存器B，禁止周期性中断，开放更新结束后中断，BCD码，24小时制
    out 0x71, al 

    in al, 0xa1                                     ; 读 8259 从片的 IMR 寄存器
    and al, 0xfe                                    ; 清除 bit 0(此位连接RTC)
    out 0xa1, al                                    ; 写回此寄存器

    sti 

    mov al, 0x0c 
    out 0x70, al    
    in al, 0x71                                     ; 读 RTC 寄存器 C, 复位未决的中断状态

    ; 以下创建进程
    mov r8, 50
    call create_process

    mov rbx, [rel pcb_ptr]                          ; 得到外壳任务 PCB 的线性地址
    mov rax, [rbx + 56]                             ; 从 PCB 中取出 CR3
    mov cr3, rax                                    ; 切换到新进程的地址空间, cr3 寄存器中存储当前四级头表的地址

    mov [rel cur_pcb], rbx                          ; 设置当前任务的 PCB
    mov qword [rbx + 16], 1                         ; 设置当前任务状态为忙

    mov rax, [rbx + 32]                             ; 从 PCB 中取出 RSP0
    mov rdx, [rel tss_ptr]                          ; 得到 TSS 的线性地址
    mov [rdx + 4], rax                              ; 在 TSS 中回填 RSP0

    push qword [rbx + 208]                          ; 用户程序的 SS
    push qword [rbx + 120]                          ; 用户程序的 RSP
    pushfq
    push qword [rbx + 200]                          ; 用户程序的 CS
    push qword [rbx + 192]                          ; 用户程序的 RIP

    iretq                                           ; 返回当前任务的私有空间执行

core_end:
