; 内核

%include "./common/global_defs.asm"

SECTION core_header                                 ; 内核头部
    length      dd core_end                         ; 内核总长度
    init_entry  dd init                             ; 内核入口点
    position    dq 0                                ; 内核加载虚拟地址

SECTION core_data                                   ; 内核数据段
    acpi_error  db "ACPI is not supported or data error.", 0x0d, 0x0a, 0

    num_cpus    db 0                                ; 逻辑处理器数量
    cpu_list    times 256 db 0                      ; Local APIC ID的列表
    lapic_addr  dd 0                                ; Local APIC的物理地址

    ioapic_addr dd 0                                ; I/O APIC的物理地址
    ioapic_id   db 0                                ; I/O APIC ID

    ack_cpus    db 0                                ; 处理器初始化应答计数

    clocks_1ms  dd 0                                ; 处理器在1ms内经历的时钟数

    welcome     db "Executing in 64-bit mode.Init MP", 249, 0
    cpu_init_ok db " CPU(s) ready.", 0x0d, 0x0a, 0

    buffer      times 256 db 0

    sys_entry   dq get_screen_row
                dq get_cmos_time
                dq put_cstringxy64
                dq create_process
                dq get_current_pid
                dq terminate_process
                dq get_cpu_number
    pcb_ptr     dq 0                                ; 进程控制块PCB首节点的线性地址


SECTION core_code                                   ; 内核代码段

%include "./common/core_utils64.asm"
%include "./common/user_static64.asm"

    [bits 64]


_ap_string      db 249, 0

; ------------------------------------------------------------
; ap_to_core_entry
; 功能: 应用处理器（AP）进入内核的入口点
; ------------------------------------------------------------
ap_to_core_entry:
    ; 启用 GDT 的高端线性地址并加载 IDTR
    mov rax, UPPER_SDA_LINEAR
    lgdt [rax + 0]                                  ; 只有 64 位模式下才能加载 64 位线性地址
    lidt [rax + 0x0c]

    ; 为当前处理器创建 64 位 模式下专属栈
    mov rcx, 4096
    call core_memory_allocate
    mov rsp, r14 

    ; 创建当前处理器的专属存储区(格式见书中 348 页)
    mov rcx, 256                                    ; 专属数据区长度, 含 TSS
    call core_memory_allocate
    lea rax, [r13 + 128]                            ; TSS 开始于专属存储区偏移为 128 的地方
    call make_tss_descriptor

    mov r15, UPPER_SDA_LINEAR

    ; 安装 TSS 描述符到 GDT
    mov r8, [r15 + 4]                               ; r8=gdt 的线性地址
    movzx rcx, word [r15 + 2]                       ; rcx=gdt 的界限值
    mov [r8 + rcx + 1], rsi                         ; TSS 描述符的低 64 位
    mov [r8 + rcx + 9], rdi                         ; TSS 描述符的高 64 位

    add word [r15 + 2], 16                          ; TSS 大小
    lgdt [r15 + 2]                                  ; 重新加载 GDTR

    shr cx, 3                                       ; 除 8 得到索引
    inc cx                                          ; 找到 TSS 描述符
    shl cx, 3                                       ; 乘 8 得到正确偏移

    ltr cx                                          ; 为当前任务加载任务寄存器 TR

    ; 将处理器专属数据区首地址保存到当前处理器的型号专属寄存器 IA32_KERNEL_GS_BASE
    mov ecx, 0xc000_0102                            ; IA32_KERNEL_GS_BASE
    mov rax, r13                                    ; 只用 EAX
    mov rdx, r13 
    shr rdx, 32 
    wrmsr 

    ; 为快速系统调用 SYSCALL 和 SYSRET 准备参数
    mov ecx, 0x0c0000080                            ; 指定型号专属寄存器 IA32_EFER
    rdmsr 
    bts eax, 0                                      ; 设置 SCE 位，允许 SYSCALL 指令
    wrmsr

    mov ecx, 0xc0000081                             ; STAR
    mov edx, (RESVD_DESC_SEL << 16) | CORE_CODE64_SEL
    wrmsr

    mov ecx, 0xc0000082                             ; LSTAR
    mov rax, [rel position]
    lea rax, [rax + syscall_procedure]              ; 只用 EAX 部分
    mov rdx, rax
    shr rdx, 32                                     ; 使用 EDX 部分
    wrmsr

    mov ecx, 0xc0000084                             ; FMASK
    xor edx, edx
    mov eax, 0x00047700                             ; 要求 TF=IF=DF=AC=0, IOPL=00
    wrmsr

    mov r15, [rel position]
    lea rbx, [r15 + _ap_string]
    call put_string64

    swapgs                                          ; 准备用 GS 操作当前处理器的专属数据, IA32_KERNEL_GS_BASE 与 GS 互换内容
    mov qword [gs:8], 0                             ; PCB 的线性地址 = 0, 没有正在执行的任务
    xor rax, rax 
    mov al, byte [rel ack_cpus]
    mov [gs:16], rax                                ; 设置处理器编号
    mov [gs:24], rsp                                ; 保存当前处理器的固有栈指针
    swapgs

    inc byte [rel ack_cpus]                         ; 递增应答计数值

    mov byte [AP_START_UP_ADDR + lock_var], 0       ; 释放自旋锁

    mov rsi, LAPIC_START_ADDR                       ; Local APIC 的线性地址
    bts dword [rsi + 0xf0], 8                       ; 设置 SVR 寄存器, 允许 LAPIC

    sti                                             ; 开放中断

.do_idle:
    hlt 
    jmp .do_idle

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

exceptm         db "A exception raised, halt.", 0   ; 发生异常时的错误信息

; ------------------------------------------------------------
; search_for_a_ready_task
; 功能: 查找一个就绪的任务并将其置为忙, 本程序在中断处理过程内调用，默认中断是关闭状态。
; 输出: r11=就绪任务的 PCB 线性地址
; ------------------------------------------------------------
search_for_a_ready_task:
    push rax 
    push rbx 
    push rcx 

    mov rcx, 1                                      ; rcx=任务的“忙”状态

    swapgs 
    mov rbx, [gs:8]                                 ; 取得当前任务的 PCB 线性地址
    swapgs
    mov r11, rbx 
    cmp rbx, 0                                      ; 专属数据区存的 PCB 线性地址为 0, 也就是刚初始化
    jne .again
    mov rbx, [rel pcb_ptr]                          ; 那就从链表头部开始找
    mov r11, rbx 
.again:
    mov r11, [r11 + 280]                            ; 取得下一个节点
    xor rax, rax 
    lock cmpxchg [r11 + 16], rcx                    ; 原子操作, 详情见 374 页
    jz .return
    cmp r11, rbx                                    ; 是否转一圈回到当前节点?
    je .fmiss                                       ; 是, 未找到就绪任务
    jmp .again

.fmiss:
    xor r11, r11 
.return:
    pop rcx 
    pop rbx 
    pop rax 
    ret 

; ------------------------------------------------------------
; resume_execute_a_task
; 功能: 恢复执行一个任务
; 输入: r11=指定任务的 PCB 线性地址, 本程序在中断处理过程内调用，默认中断是关闭状态。
; ------------------------------------------------------------
resume_execute_a_task:
    mov eax, [rel clocks_1ms]                       ; 以下计算新任务运行时间
    mov ebx, [r11 + 240]                            ; 任务制定的时间片
    mul ebx 

    mov rsi, LAPIC_START_ADDR
    mov qword [rsi + 0x3e0], 0x0b                   ; 1 分频
    mov qword [rsi + 0x320], 0xfd                   ; 单次击发模式, Fixed, 中断信号 0xfd, 详情见书中 276 页

    mov rbx, [r11 + 56]
    mov cr3, rbx                                    ; 切换地址空间

    swapgs
    mov [gs:8], r11                                 ; 将新任务设置为当前任务
    ; mov qword [r11 + 16], 1                         ; 置任务状态为忙, 在 lock cmpxchg [r11 + 16], rcx 中已经被设置
    mov rbx, [r11 + 32]                             ; 取 PCB 中的 RSP0
    mov [gs:128 + 4], rbx                           ; 置 TSS 中的 RSP0
    swapgs

    mov rcx, [r11 + 80]
    mov rdx, [r11 + 88]
    mov rdi, [r11 + 104]
    mov rbp, [r11 + 112]
    mov rsp, [r11 + 120]
    mov r8, [r11 + 128]
    mov r9, [r11 + 136]
    mov r10, [r11 + 144]
    mov r12, [r11 + 160]
    mov r13, [r11 + 168]
    mov r14, [r11 + 176]
    mov r15, [r11 + 184]
    push qword [r11 + 208]                          ; SS
    push qword [r11 + 120]                          ; RSP
    push qword [r11 + 232]                          ; RFLAGS
    push qword [r11 + 200]                          ; CS
    push qword [r11 + 192]                          ; RIP

    mov dword [rsi + 0x380], eax                    ; 开始计时

    mov rax, [r11 + 64]
    mov rbx, [r11 + 72]
    mov rsi, [r11 + 96]
    mov r11, [r11 + 152]

    iretq                                           ; 转入新任务的空间执行

; ------------------------------------------------------------
; time_slice_out_handler
; 功能: 时间片到期中断的处理过程
; ------------------------------------------------------------
time_slice_out_handler:
    push rax
    push rbx 
    push r11 

    mov r11, LAPIC_START_ADDR                       ; 给 Local APIC 发送中断结束命令 EOI
    mov dword [r11 + 0xb0], 0

    call search_for_a_ready_task
    or r11, r11 
    jz .return                                      ; 未找到就绪任务

    swapgs
    mov rax, qword [gs:8]                           ; 当前任务的 PCB 线性地址
    swapgs

    ; 保存当前任务的状态以便将来恢复执行。
    mov rbx, cr3                                    ; 保存原任务的分页系统
    mov qword [rax + 56], rbx
    ; mov [rax + 64], rax                            ; 不需设置，将来恢复执行时从栈中弹出
    ; mov [rax + 72], rbx                            ; 不需设置，将来恢复执行时从栈中弹出
    mov [rax + 80], rcx
    mov [rax + 88], rdx
    mov [rax + 96], rsi
    mov [rax + 104], rdi
    mov [rax + 112], rbp
    mov [rax + 120], rsp
    mov [rax + 128], r8
    mov [rax + 136], r9
    mov [rax + 144], r10
    ;mov [rax + 152], r11                           ; 不需设置，将来恢复执行时从栈中弹出
    mov [rax + 160], r12
    mov [rax + 168], r13
    mov [rax + 176], r14
    mov [rax + 184], r15
    mov rbx, [rel position]
    lea rbx, [rbx + .return]                        ; 将来恢复执行时，是从中断返回
    mov [rax + 192], rbx                            ; RIP域为中断返回点
    mov [rax + 200], cs
    mov [rax + 208], ss
    pushfq
    pop qword [rax + 232]

    mov qword [rax + 16], 0                         ; 置任务状态为就绪

    jmp resume_execute_a_task                       ; 恢复并执行新任务

.return:
    pop r11
    pop rbx 
    pop rax 
    iretq

; ------------------------------------------------------------
; new_task_notify_handler
; 功能: 新任务创建后，将广播新任务创建消息给所有处理器，所有处理器执行此中断服务例程。
; ------------------------------------------------------------
new_task_notify_handler:
    push rsi 
    push r11 

    mov rsi, LAPIC_START_ADDR                       
    mov dword [rsi + 0xb0], 0                       ; 发送 EOI

    swapgs
    cmp qword [gs:8], 0                             ; 当前处理器没有任务执行吗?
    swapgs
    jne .return 

    call search_for_a_ready_task
    or r11, r11 
    jz .return                                      ; 未找到就绪任务

    add rsp, 16,                                    ; 去掉前面压入的两个
    mov qword [gs:24], rsp                          ; 保存固有栈当前指针, 以便将来返回, 在进入中断时 RIP → CS → RFLAGS → RSP → SS 按顺序入栈
    swapgs

    jmp resume_execute_a_task                       ; 执行新任务

.return:
    pop r11
    pop rsi 
    iretq 

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
; append_to_pcb_link
; 功能: 在 PCB 链上追加任务控制块
; 输入: r11=PCB 线性基地址
; ------------------------------------------------------------
_append_lock dq 0

append_to_pcb_link:
    push rax 
    push rbx 

    pushfq
    cli 
    SET_SPIN_LOCK rax, qword [rel _append_lock]

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
    mov qword [rel _append_lock], 0
    popfq

    pop rbx 
    pop rax 

    ret 

; ------------------------------------------------------------
; get_current_pid
; 功能: 返回当前任务（进程）的标识
; 输出: rax=当前任务（进程）的标识
; ------------------------------------------------------------
get_current_pid:
    pushfq
    cli 
    swapgs
    mov rax, [gs:8]
    mov rax, [rax + 8]
    swapgs
    popfq

    ret 

; ------------------------------------------------------------
; terminate_process
; 功能: 终止当前任务
; ------------------------------------------------------------
terminate_process:
    mov rsi, LAPIC_START_ADDR
    mov dword [rsi + 0x320], 0x00010000             ; 屏蔽定时器中断

    cli                                             ; 执行流改变期间禁止时钟中断引发的任务切换

    swapgs
    mov rax, [gs:8]                                 ; PCB 线性地址
    mov qword [rax + 16], 2                         ; 任务状态=终止
    mov qword [gs:0], 0
    mov rsp, [gs:24]                                ; 切换到处理器固有栈
    swapgs

    call search_for_a_ready_task
    or r11, r11 
    jz .sleep                                       ; 未找到就绪任务

    jmp resume_execute_a_task                       ; 执行新任务

.sleep:
    iretq

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

    mov qword [r11 + 240], SUGG_PREEM_SLICE         ; 推荐的执行时间片

    call generate_process_id
    mov [r11 + 8], rax                              ; 填入 PCB 中当前任务标识

    call append_to_pcb_link                         ; 将 PCB 添加到进程控制链表尾部

    mov cr3, r15                                    ; 切换到原任务地址空间

    mov rsi, LAPIC_START_ADDR                       ; Local APIC 的线性地址
    mov dword [rsi + 0x310], 0
    mov dword [rsi + 0x300], 0x000840fe             ; 向所有处理器发送任务认领中断

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
; 功能: 系统调用的处理过程, 处理器会自动关闭可屏蔽中断
; 注意: rcx 和 r11 由处理器使用, 保存 rip 和 rflags 的内容; rbp 和 r15 由此例程占用. 如有必要, 请用户程序在调用 syscall 前保存它们, 在系统调用返回后自行恢复.
; ------------------------------------------------------------
syscall_procedure: 

    swapgs
    mov [gs:0], rsp                                 ; 保存当前 3 特权级栈指针
    mov rsp, [gs:128 + 4],                          ; 使用 TSS 的 RSP0 作为安全栈
    push qword [gs:0]                               
    swapgs
    sti                                             ; 准备工作全部完成，中断和任务切换无虞

    push r15 
    mov r15, [rel position]
    add r15, [r15 + rax * 8 + sys_entry]            ; 得到指定的那个系统调用功能的线性地址
    call r15
    pop r15 

    cli 
    pop rsp                                         ; 恢复原先的 3 特权级栈指针
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

    mov al, 0xff                                    ; 屏蔽所有发往 8259A 主芯片的中断信号
    out 0x21, al                                    ; 多处理器下不再使用 8259 芯片

    ; 在 64 位模式下显示的第一条信息!
    mov r15, [rel position]
    lea rbx, [r15 + welcome]
    call put_string64                               ; 在 core_utils64.asm 中实现

    ; 安装系统服务(syscall, sysret)所需的代码段和栈段描述符
    mov r15, UPPER_SDA_LINEAR                       ; 系统数据区 SDA 的线性地址
    xor rbx, rbx 
    mov bx, [r15 + 2]                               ; 得到 GDT 界限值(表的总字节数 - 1 == 下标)
    inc bx 
    add rbx, [r15 + 4]                              ; GDT 基址 + GDT 界限值 + 1 == 新描述符的地址
                        
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

    ; 我们为每个逻辑处理器都准备一个专属数据区, 它是由每个处理器的 GS 所指向的。
    ; 为当前处理器(BSP)准备专属数据区, 设置 GS 并安装任务状态段 TSS 的描述符
    ; 详情见书中 348 页
    mov rcx, 256                                    ; 专属数据区长度
    call core_memory_allocate                       ; 在 core_utils64.asm 中实现
    mov qword [r13 + 8], 0                          ; 当前任务的 PCB 指针, 初始化为 0
    mov qword [r13 + 16], 0                         ; 将当前的处理器编号设置为 #0
    mov [r13 + 24], rsp                             ; 当前处理器的专属栈
    lea rax, [r13 + 128]                            ; TSS 开始于专属数据区内偏移为 128 的地方
    call make_tss_descriptor
    mov qword [rbx + 32], rsi                       ; TSS 描述符的低 64 位
    mov qword [rbx + 40], rdi                       ; TSS 描述符的高 64 位

    add word [r15 + 2], 48                          ; 更新 GDT 的边界值, 48 是四个段描述符和一个 TSS 描述符的字节数
    lgdt [r15 + 2]

    mov cx, 0x0040                                  ; TSS 描述符选择子
    ltr cx                                          ; 使用 ltr 指令加载 TSS 选择子

    ; 将处理器专属数据区首地址保存到当前处理器的型号专属寄存器 IA32_KERNEL_GS_BASE
    mov ecx, 0xc000_0102                            ; IA32_KERNEL_GS_BASE
    mov rax, r13                                    ; 只用 eax
    mov rdx, r13 
    shr rdx, 32                                     ; 只用 edx
    wrmsr

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

    ; 以下初始化高级可编程中断控制器 APIC。在计算机启动后，BIOS已经对 LAPIC 和 IOAPIC 做了
    ; 初始化并创建了相关的高级配置和电源管理接口（ACPI）表项。可以从中获取多处理器和
    ; APIC 信息。英特尔架构的个人计算机（IA-PC）从 1MB 物理内存中搜索获取；启用可扩展固件
    ; 接口（EFI或者叫UEFI）的计算机需使用 EFI 传递的 EFI 系统表指针定位相关表格并从中获取
    ; 多处理器和 APIC 信息。为简单起见，我们采用前一种传统的方式。请注意虚拟机的配置！

    ; ACPI 申领的内存区域已经保存在我们的系统数据区（SDA），以下将其读出。此内存区可能
    ; 位于分页系统尚未映射的部分，故以下先将这部分内存进行一一映射（线性地址=物理地址）
    cmp word [SDA_PHY_ADDR + 0x16], 0               ; 检查检查地址范围描述结构的数量是否为 0
    jz .acpi_err                                    ; 除非 bios 不支持 acpi, 否则不会是 0
    mov rsi, SDA_PHY_ADDR + 0x18                    ; 系统数据区, 地址范围描述结构的起始地址
.looking:
    cmp dword [rsi + 16], 3                         ; 3 代表是 ACPI 申领的内存, ACPI 的介绍可以看书中 257 页
    jz .looked
    add rsi, 32                                     ; 每个地址范围描述结构的长度
    loop .looking

.acpi_err:
    mov r15, [rel position]
    lea rbx, [r15 + acpi_error]
    call put_cstringxy64
    cli 
    hlt 

.looked:
    mov rbx, [rsi]                                  ; ACPI 申领的起始物理地址
    mov rcx, [rsi + 8]                              ; ACPI 申领的内存大小, 以字节计
    add rcx, rbx                                    ; ACPI 申领的内存上边界
    mov rdx, 0xffff_ffff_ffff_f000                  ; 用于生成页地址的掩码

.mapping:
    mov r13, rbx                                    ; 映射的线性地址
    mov rax, rbx 
    and rax, rdx 
    or rax, 0x07                                    ; 将地址设置上属性
    call mapping_laddr_to_page
    add rbx, 0x1000
    cmp rbx, rcx 
    jle .mapping

    ; 从物理地址 0x60000(常规内存顶端) 开始, 搜索系统描述指针结构(RSDP)
    mov rbx, 0x60000
    mov rcx, "RSD PTR "                             ; 结构起始标记

.searc:
    cmp qword [rbx], rcx
    je .finda 
    add rbx, 16                                     ; 结构的标记位于 16 字节边界处, 也就是说可以以 16 字节为单位搜索
    cmp rbx, 0xffff0                                ; 搜索上边界
    jl .searc 
    jmp .acpi_err                                   ; 未找到 RSDP, 报错停机

.finda:
    ; RSDT 和 XSDT 都指向 MADT, 但 RSDT 给出的是 32 位物理地址, 而 XDST 给出 64 位物理地址。
    ; 只有 VCPI 2.0 及更高版本才有 XSDT。典型地, VBox 支持 ACPI 2.0 而 Bochs 仅支持 1.0
    ; 这个可以看书中 274 往后的几个图
    cmp byte [rbx + 15], 2                          ; 检测 ACPI 的版本是否为 2
    jne .acpi_1
    mov rbx, [rbx + 24]                             ; 得到扩展的系统描述表 XSDT 的物理地址

    ; 以下开始在 XSDT 中遍历搜索多 APIC 描述符表, 即 MADT
    xor rdi, rdi                                    ; 下面要使用 rdi, 尽管 edi 赋值了, 但还是要清空 rdi
    mov edi, [rbx + 4]                              ; 得到 XSDT 长度, 以字节计
    add rdi, rbx                                    ; 计算上边界的物理地址
    add rbx, 36                                     ; XSDT 尾部数组的物理地址
.madt0:
    mov r11, [rbx]             
    cmp dword [r11], "APIC"                         ; MADT 表的标记
    je .findm                       
    add rbx, 8                                      ; 下一个元素
    cmp rbx, rdi  
    jl .madt0
    jmp .acpi_err

    ; 一些处理 VCPI 1.0, 在 RSDT 中遍历搜索 MADT
.acpi_1:
    mov ebx, [rbx + 16]                             ; 得到根系统描述符表 RSDT 的物理地址
    mov edi, [ebx + 4]                              ; 得到 RSDT 的长度, 以字节计
    add edi, ebx                                    ; 上边界物理地址
    add ebx, 36                                     ; 尾部数组的物理地址
    xor r11, r11 
.madt1:
    mov r11d, [ebx]
    cmp dword [r11], "APIC"                         ; MADT 表的标记
    je .findm
    add ebx, 4
    cmp ebx, edi 
    jl .madt1
    jmp .acpi_err

.findm:
    ; 此时, r11 是 MADT 的物理地址
    mov edx, [r11 + 36]                             ; 预置的 Local APIC 物理地址
    mov [rel lapic_addr], ebx

    ; 以下开始遍历系统中的逻辑处理器的 LAPIC ID 和 I/O APIC
    mov r15, [rel position]
    lea r15, [r15 + cpu_list]

    xor rdi, rdi 
    mov edi, [r11 + 4]                              ; MADT 的长度
    add rdi, r11                                    ; 上边界物理地址
    add r11, 44                                     ; 指向 MADT 尾部中断控制器结构列表
.enumd:
    cmp byte [r11], 0                               ; 0 代表 Local APIC
    je .l_apic
    cmp byte [r11], 1                               ; 1 代表 I/O APIC
    je .ioapic
    jmp .m_end 
.l_apic:
    cmp dword [r11 + 4], 0                          ; Local APIC flag
    jz .m_end
    mov al, [r11 + 3]                                ; 获取 Local APIC ID
    mov [r15], al                                   ; 保存 Local APIC ID 到 cpu_list
    inc r15
    inc byte [rel num_cpus]                         ; 原来 cpu 数量是这么统计出来的
    jmp .m_end
.ioapic:
    mov al, [r11 + 2]                               ; 取出 I/O APIC ID
    mov [rel ioapic_id], al                         ; 保存 I/O APIC ID
    mov eax, [r11 + 4]                              ; 取出 I/O APIC 物理地址
    mov [rel ioapic_addr], eax                      ; 保存 I/O APIC ID 物理地址
.m_end:
    xor rax, rax 
    mov al, [r11 + 1]
    add r11, rax                                    ; 计算出下一个中断控制结构列表的物理地址
    cmp r11, rdi 
    jl .enumd

    ; 遍历完成, 映射物理地址到内核指定区域

    ; Local APIC -> LAPIC_START_ADDR
    mov r13, LAPIC_START_ADDR
    xor rax, rax 
    mov eax, [rel lapic_addr]                       ; 取出 LAPIC 的物理地址
    or eax, 0x1f                                    ; 设置属性, PCD=PWT=U/S=R/W=P=1, 强不可缓存
    call mapping_laddr_to_page
    ; I/O APIC -> IOAPIC_START_ADDR
    mov r13, IOAPIC_START_ADDR
    xor rax, rax 
    mov eax, [rel ioapic_addr]
    or eax, 0x1f  
    call mapping_laddr_to_page

    ; 以下测量当前处理器 1ms 内经历了多少时钟周期, 作为后续的定时基准, 详情见书中284 页
    mov rsi, LAPIC_START_ADDR

    mov dword [rsi + 0x320], 0x10000                ; 定时器的本地向量表入口寄存器, 单次击发模式
    mov dword [rsi + 0x3e0], 0x0b                   ; 定时器的分频配置寄存器: 1 分频

    mov al, 0x0b                                    ; RTC 寄存器 B                                     
    or al, 0x80                                     ; 阻断 NMI
    out 0x70, al            
    mov al, 0x52                                    ; 设置寄存器 B, 开发周期性中断, 开放更新结束后中断, BCD 码, 24 小时制
    out 0x71, al 

    mov al, 0x8a                                    ; CMOS 寄存器 A
    out 0x70, al 
    mov al, 0x2d                                    ; 32 kHz, 125 ms 的周期性中断
    out 0x71, al                                    ; 写回 CMOS 寄存器 A

    mov al, 0x8c
    out 0x70, al 
    in al, 0x71                                     ; 读寄存器 C
.w0:
    in al, 0x71 
    bt rax, 6                                       ; 更新周期结束中断已发生
    jnc .w0 
    mov dword [rsi + 0x380], 0xffff_ffff            ; 定时器初始计数寄存器: 置初始值并开始计数
.w1:
    in al, 0x71     
    bt rax, 6   
    jnc .w1 
    mov edx, [rsi + 0x390],                         ; 定时器初始计数寄存器: 读当前计数值

    mov eax, 0xffff_ffff
    sub eax, edx 
    xor edx, edx 
    mov ebx, 125                                    ; 125ms
    div ebx                                         ; 结果存在 eax 中, 即当前处理器在 1ms 内的时钟数

    mov [rel clocks_1ms], eax                       ; 记录

    mov al, 0x0b                                    ; RTC 寄存器 B
    or al, 0x80                                     ; 阻断 NMI
    out 0x70, al 
    mov al, 0x12                                    ; 设置寄存器 B, 只允许更新周期结束中断
    out 0x71, al 

    ; 安装用于任务切换的中断处理过程
    mov r9, [rel position]
    lea rax, [r9 + new_task_notify_handler]         ; 得到中断处理过程的线性地址
    call make_interrupt_gate                        

    cli 
    mov r8, 0xfe                                    ; 任务切换使用的中断向量, 数越大, 优先级越高
    call mount_idt_entry
    sti 

    ; 以下安装时间片到期中断处理过程
    mov r9, [rel position]
    lea rax, [r9 + time_slice_out_handler]          ; 得到中断处理过程的线性地址
    call make_interrupt_gate            

    cli 
    mov r8, 0xfd 
    call mount_idt_entry
    sti

    ; 以下初始化应用处理器 AP, 先将初始化代码复制到物理内存的选定位置
    mov rsi, [rel position]
    lea rsi, [rsi + section.ap_init_block.start]    ; 源
    mov rdi, AP_START_UP_ADDR                       ; 目的地
    mov rcx, ap_init_tail - ap_init                 ; 次数
    cld 
    repe movsb 

    ; 所有处理器都应该在初始化期间递增应答计数值
    inc byte [rel ack_cpus]                         ; BSP 自己的应答计数值

    ; 给其它处理器发送 INIT IPI 和 SIPI, 命令他们初始化自己
    mov rsi, LAPIC_START_ADDR
    mov dword [rsi + 0x310], 0
    mov dword [rsi + 0x300], 0x000c4500             ; 先发送 INIT IPI
    mov dword [rsi + 0x300], (AP_START_UP_ADDR >> 12) | 0x000c4600      ; start up IPI
    mov dword [rsi + 0x300], (AP_START_UP_ADDR >> 12) | 0x000c4600      ; 保险起见发两次

    mov al, [rel num_cpus]

.wcpus:
    cmp al, [rel ack_cpus]
    jne .wcpus                                      ; 等待所有应用处理器的应答

    ; 显示已应答的处理器数量
    mov r15, [rel position]

    xor r8, r8 
    mov r8b, [rel ack_cpus]
    lea rbx, [r15 + buffer]
    call bin64_to_dec
    call put_string64

    lea rbx, [r15 + cpu_init_ok]
    call put_string64

    ; 以下创建进程
    mov r8, 50
    call create_process

    jmp ap_to_core_entry.do_idle                    ; 去处理器集结休息区

section ap_init_block vstart=0                      ; vstart 改变段内汇编地址, 让其都相对于段起始, 即这段代码是浮动的

    bits 16                                         ; 应用处理器 AP 从实模式开始

ap_init:
    mov ax, AP_START_UP_ADDR >> 4
    mov ds, ax 

    SET_SPIN_LOCK al, byte [lock_var]               ; 自旋知道获得锁

    mov ax, SDA_PHY_ADDR >> 4                       ; 切换到系统数据区
    mov ds, ax 

    lgdt [2]                                        ; 加载描述符寄存器 GDTR, 实模式下只加载 6 字节的内容, 界限值 2 字节, 基地址 4 字节, 描述符已经填好

    in al, 0x92                                     ; 南桥芯片内端口
    or al, 0000_0010B
    out 0x92, al                                    ; 打开 A20

    cli                                             ; 中断机制尚未工作

    mov eax, cr0
    or eax, 1
    mov cr0, eax                                    ; 设置 PE 位

    ; 进入保护模式...
    jmp 0x0008: AP_START_UP_ADDR + .flush           ; 0x0008 是保护模式下的代码段描述符的选择子, 清流水线并串行化处理器

    [bits 32]
.flush:
    mov eax, 0x0010                                 ; 加载数据段(4gb)选择子
    mov ss, eax                                     ; 加载堆栈段(4gb)选择子
    mov esp, 0x7e00                                 ; 堆栈指针

    ; 令 CR3 寄存器指向 4 级表头(保护模式下的 32 位 CR3)
    mov eax, PML4_PHY_ADDR                          ; PCD = PWT = 0
    mov cr3, eax 

    ; 开启物理地址扩展 PAE
    mov eax, cr4 
    bts eax, 5
    mov cr4, eax 

    ; 设置型号专属寄存器 IA32_EFER.LME，允许 IA_32e 模式
    mov ecx, 0x0c0000080                            ; 指定型号专属寄存器 IA32_EFER
    rdmsr 
    bts eax, 8                                      ; 设置 LME 位
    wrmsr

    ; 开启分页功能
    mov eax, cr0 
    bts eax, 31                                     ; 置位 CR0.PG
    mov cr0, eax 

    ; 进入 64 位模式
    jmp CORE_CODE64_SEL:AP_START_UP_ADDR + .to64
.to64:
    bits 64

    ; 转入内核中继续初始化, 使用高端线性地址
    mov rbx, UPPER_CORE_LINEAR + ap_to_core_entry
    jmp rbx 

lock_var db 0

ap_init_tail:

section core_tail
core_end:
