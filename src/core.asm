; 内核

%include "./common/global_defs.asm"

SECTION core_header                                 ; 内核头部
    length      dd core_end                         ; 内核总长度
    init_entry  dd init                             ; 内核入口点
    position    dq 0                                ; 内核加载虚拟地址

SECTION core_data                                   ; 内核数据段
    welcome     db "Executing in 64-bit mode.", 0x0d, 0x0a, 0   
    tss_ptr     dq 0                                ; 任务状态段 TSS 从此处开始
    sys_entry   dq get_screen_row                   ; syscall 支持的功能
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

exceptm         db "A exception raised, halt.", 0    ; 发生异常时的错误信息

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
    ; 进入中断时, 硬件自动关闭可屏蔽中断, iret 指令自动恢复中断发生前的 IF 状态，无需软件手动设置

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
    ; 任务切换的原理是, 它发生在所有任务的全局空间。在任务 A 的全局空间执行任务切换，切换到任务 B, 实际上也是从任务 B 的全局空间返回任务B的私有空间。

    ; 从 PCB 链表中寻找就绪任务
    mov r8, [rel cur_pcb]                           ; 定位当前任务的 PCB 节点
.again:
    mov r8, [r8 + 280]                              ; 获取下一个节点
    cmp r8, [rel cur_pcb]                           ; 是否转一圈回到当前节点?
    jz .return                                      ; 返回
 
    cmp qword [r8 + 16], 0                          ; 是否是就绪任务?
    jz .found                                       ; 切换任务
    jmp .again  

.found:
    mov rax, [rel cur_pcb]                          ; 取得当前任务的 PCB 的线性地址
    cmp qword [rax + 16], 2                         ; 当前任务可能已经被标记为终止, 我们就不用保存当前任务状态
    jz .restore

    ; 保存当前任务的状态以便将来恢复执行
    mov qword [rax + 16], 0                         ; 置任务状态为就绪
    ; mov [rax + 64], rax                           ; 不需设置，将来恢复执行时从栈中弹出, 因为下面把当前任务的 rip 设置成了 .return, 也就是, 当这个任务在被切换到时, 会从 .return 开始执行, pop rax ...
    ; mov [rax + 72], rbx                           ; 不需设置，将来恢复执行时从栈中弹出
    mov [rax + 80], rcx
    mov [rax + 88], rdx
    mov [rax + 96], rsi
    mov [rax + 104], rdi
    mov [rax + 112], rbp
    mov [rax + 120], rsp
    ; mov [rax + 128], r8                           ; 不需设置，将来恢复执行时从栈中弹出
    mov [rax + 136], r9
    mov [rax + 144], r10
    mov [rax + 152], r11
    mov [rax + 160], r12
    mov [rax + 168], r13
    mov [rax + 176], r14
    mov [rax + 184], r15
    mov rbx, [rel position]
    lea rbx, [rbx + .return]
    mov [rax + 192], rbx                            ; RIP 为中断返回点
    mov [rax + 200], cs
    mov [rax + 208], ss
    pushfq
    pop qword [rax + 232]

.restore:
    ; 恢复新任务的状态
    mov [rel cur_pcb], r8                           ; 将当前任务设置为新任务
    mov qword [r8 + 16], 1                          ; 置任务状态为忙

    mov rax, [r8 + 32]                              ; 取 PCB 中的 RSP0
    mov rbx, [rel tss_ptr]
    mov [rbx + 4], rax                              ; 置 TSS 的 RSP0

    mov rax, [r8 + 56]                              ; 设置 cr3, 切换地址空间
    mov cr3, rax 

    mov rax, [r8 + 64]
    mov rbx, [r8 + 72]
    mov rcx, [r8 + 80]
    mov rdx, [r8 + 88]
    mov rsi, [r8 + 96]
    mov rdi, [r8 + 104]
    mov rbp, [r8 + 112]
    mov rsp, [r8 + 120]
    mov r9, [r8 + 136]
    mov r10, [r8 + 144]
    mov r11, [r8 + 152]
    mov r12, [r8 + 160]
    mov r13, [r8 + 168]
    mov r14, [r8 + 176]
    mov r15, [r8 + 184]

    push qword [r8 + 208]                           ; SS
    push qword [r8 + 120]                           ; RSP
    push qword [r8 + 232]                           ; RFLAGS
    push qword [r8 + 200]                           ; CS
    push qword [r8 + 192]                           ; RIP

    mov r8, [r8 + 128]                              ; 恢复 R8 的值

    iretq                                           ; 转入新任务局部空间执行

.return:
    pop rbx 
    pop rax 
    pop r8 

    iretq

; ------------------------------------------------------------
; append_to_pcb_link
; 功能: 在 PCB 链上追加任务控制块
; 输入: r11=PCB 线性基地址
; ------------------------------------------------------------
append_to_pcb_link:
    push rax 
    push rbx 

    cli 

    mov rbx, [rel pcb_ptr]                          ; 取得链表首节点的线性地址
    or rbx, rbx 
    jnz .not_empty                                  ; 链表非空就跳转
    mov [r11], r11                                  ; 唯一的节点, 前驱是自己
    mov [r11 + 280], r11                            ; 后继节点也是自己
    mov [rel pcb_ptr], r11                          ; 填入内核
    jmp .return 

.not_empty:
    ; rbx=头节点, rax=头节点的前驱节点, r11=追加的节点
    mov rax, [rbx]                                  ; 取得头节点的前驱线性地址
    mov [rax + 280], r11                            ; 头节点的后继是追加节点
    mov [r11 + 280], rbx                            ; 追加节点的后继是头节点
    mov [r11], rax                                  ; 追加节点的前驱是头节点的前驱
    mov [rbx], r11                                  ; 头节点的前驱是追加节点

.return:
    sti 

    pop rbx 
    pop rax 

    ret 

; ------------------------------------------------------------
; get_current_pid
; 功能: 返回当前任务（进程）的标识
; 输出: rax=当前任务（进程）的标识
; ------------------------------------------------------------
get_current_pid:
    mov rax, [rel cur_pcb]
    mov rax, [rax + 8]

    ret 

; ------------------------------------------------------------
; terminate_process
; 功能: 终止当前任务
; ------------------------------------------------------------
terminate_process:
    cli                                             ; 执行流改变期间禁止时钟中断引发的任务切换

    mov rax, [rel cur_pcb]                          ; 定位到当前任务的 PCB 节点
    mov qword [rax + 16], 2                         ; 状态=终止
    
    jmp rtm_interrupt_handle                        ; 执行任务调度, 将控制权交给处理器

; ------------------------------------------------------------
; create_process
; 功能: 创建新的任务, 即分配好空间, 创建并填入 PCB
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

    ; 以下，切换到新任务的地址空间，并清空其 4 级头表的前半部分。
    ; 我们正在地址空间的高端执行，可正常执行内核代码并访问内核数据，同时，当前使用的栈位于地址空间高端的栈。
    mov r15, cr3                                    ; 保存控制寄存器, 本次是临时切换, 还要再切回来
    mov cr3, rax                                    ; 切换到新四级头表的新地址空间

    ; 清空四级头表的前半部分, 即局部地址
    mov rax, 0xffff_ffff_ffff_f000                  ; 四级头表线性地址, 还是递归映射...
    mov rcx, 256
.clsp:
    mov qword [rax], 0
    add rax, 8
    loop .clsp

    mov rax, cr3                                    ; 刷新 TLB
    mov cr3, rax 

    ; 为新任务分配 0 特权级使用的栈空间
    mov rcx, 4096 * 16                              ; 在内核地址开辟空间
    call core_memory_allocate
    mov [r11 + 32], r14                             ; 填入 PCB 中 RSP0, 满减栈, 所以写入结尾地址

    ; 为新任务分配 3 特权级使用的栈空间
    mov rcx, 4096 * 16                              ; 在用户地址开辟空间
    call user_memory_allocate
    mov [r11 + 120], r14                            ; 填入 PCB 中 RSP

    mov qword [r11 + 16], 0                         ; PCB 中的任务状态填为就绪    

    ; 以下开始加载用户程序
    mov rcx, 512                                    ; 在用户空间开辟一个缓冲区
    call user_memory_allocate
    mov rbx, r13 
    mov rax, r8                                     ; r8 中存的用户程序起始扇区号         
    call read_hard_disk_0

    mov [r13 + 16], r13                             ; 在程序头填写它自己的起始线性地址
    mov r14, r13 
    add r14, [r13 + 8]
    mov [r11 + 192], r14                            ; 在 PCB 中登记程序入口的线性地址

    ; 以下读取程序剩下代码
    mov rcx, [r13]                                  ; 程序尺寸(在程序头部记录)
    test rcx, 0x1ff                                 ; 能被 512 整除吗?
    jz .y512
    shr rcx, 9                                      ; 不能就凑整
    shl rcx, 9
    add rcx, 512
.y512:
    sub rcx, 512                                    ; 减去已读一个扇区的长度
    jz .rdok 
    call user_memory_allocate                       ; 先分配内存在读数据
    shr rcx, 9                                      ; 除以 512, 计算还需要读的扇区数
    inc rax                                         ; 起始扇区号
.b1:
    call read_hard_disk_0
    inc rax 
    loop .b1 

.rdok:
    mov qword [r11 + 200], USER_CODE64_SEL          ; 填写 PCB 中代码段选择子
    mov qword [r11 + 208], USER_STACK64_SEL         ; 填写 PCB 中栈段选择子

    pushfq
    pop qword [r11 + 232]                           ; 填写 PCB 中 RFLAGS

    call generate_process_id
    mov [r11 + 8], rax                              ; 填入 PCB 中当前任务标识

    call append_to_pcb_link                         ; 将 PCB 添加到进程控制链表尾部

    mov cr3, r15                                    ; 切换到原任务地址空间

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ret
; ------------------------------------------------------------
; syscall_procedure
; 功能: 系统调用的处理过程
; 注意: rcx 和 r11 由处理器使用, 保存 rip 和 rflags 的内容; rbp 和 r15 由此例程占用. 如有必要, 请用户程序在调用 syscall 前保存它们, 在系统调用返回后自行恢复.
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
    mov [rel tss_ptr], r13 
    mov rax, r13 
    call make_tss_descriptor                        ; 在 core_utils64.asm 中实现
    mov qword [rbx + 32], rsi                       ; TSS 描述符低 64 位
    mov qword [rbx + 40], rdi                       ; TSS 描述符高 64 位

    add word [rsp], 48                              ; 四个段描述符和一个 TSS 描述符总字节数
    lgdt [rsp]
    add rsp, 16                                     ; 栈平衡

    mov cx, 0x0040                                  ; TSS 描述符选择子
    ltr cx                                          ; 使用 ltr 指令加载 TSS 选择子

    ; 为快速系统调用 syscall 和 sysret 准备参数, 详细见书中 180-185
    mov ecx, 0x0c0000080                            ; 指定型号专属寄存器 IA32_EFER
    rdmsr
    bts eax, 0                                      ; 置位 SCE 位, 允许 syscall 和 sysret
    wrmsr

    mov ecx, 0xc0000081                             ; IA32_STAR, syscall 会自动切换代码段寄存器（CS）到内核态的代码段，其值来自 IA32_STAR
    mov edx, (RESVD_DESC_SEL << 16) | CORE_CODE64_SEL ; 高 32 位, RESVD_DESC_SEL 是用户态代码段选择子（返回用户态时使用）, CORE_CODE64_SEL 是内核态代码段选择子（进入内核态时使用）
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
    pushfq                                          ; 用户程序的 RFLGAS
    push qword [rbx + 200]                          ; 用户程序的 CS
    push qword [rbx + 192]                          ; 用户程序的 RIP

    iretq                                           ; 返回当前任务的私有空间执行, 弹出 rip, cs, rflags, rsp, ss 跳转

core_end:
