; 内核加载器

%include "../common/global_defs.asm"

SECTION loader
    marker          dd "lino"           ; 内核加载器有效标志    +00 将老师的 lizh, 改为了 lino, hh
    length          dd ldr_end          ; 内核加载器的长度      +04
    entry           dd start            ; 内核加载器的入口点    +08

    msg0            db "MouseHero x64 course learning.", 0x0d, 0x0a

    arch0           db "x64 available(64-bit processor installed).", 0x0d, 0x0a
    arch1           db "x64 not available(64-bit processor not installed).", 0x0d, 0x0a

    ; 汇编版格式化字符串
    brand_mag       db "Processor:"
        brand       times 48 db 0
                    db 0x0d, 0x0a

    cpu_addr        db "Physical address size:"
        paddr       times 3 db " "
                    db ","
                    db "Linear address size:"
        laddr       times 3 db " "
                    db 0x0d, 0x0a

    protect         db "Protect mode has been entered to prepare for IA-32e mode.", 0x0d, 0x0a, 0

    ia_32e          db "IA-32e mode(aka,long mode) is active.Specifically,"
                    db "compatibility mode.", 0x0d, 0x0a, 0

; ------------------------------------------------------------
; put_string_by_bios
; 功能: 在光标当前位置按指定颜色打印字符串
; 输入: bp = 字符串地址, cx = 长度, bl = 颜色属性
; 输出: 无(光标自动后移)
; ------------------------------------------------------------
put_string_by_bios:
    pusha                               ; 保存全部通用寄存器

    mov ah, 0x03                        ; 获取光标位置
    mov bh, 0x00
    int 0x10                            ; 返回 dh=行, dl=列

    mov ax, 0x1301                      ; 写字符串, 光标移动
    mov bh, 0
    int 0x10

    popa                                ; 恢复全部通用寄存器
    ret

no_ia_32e:
    mov bp, arch1
    mov cx, brand_mag - arch1
    mov bl, 0x4f
    call put_string_by_bios

    cli
    hlt


start:
    mov bp, msg0
    mov cx, arch0 - msg0
    mov bl, 0x4f                        ; 红底亮白字
    call put_string_by_bios

    ; 检查处理器是否支持 ia-32e 模式
    mov eax, 0x80000000                 ; 返回处理器支持的最大扩展功能号
    cpuid                               ; 返回值在 eax 中
    cmp eax, 0x80000001
    jb no_ia_32e                        ; 不支持就到 no_ia_32e 处执行

    mov eax, 0x80000001                 ; edx 返回扩展的签名和特性标志位
    cpuid
    bt edx, 29                          ; 低 29 位是 IA-32e 模式支持标志, bt 指令会影响 cf  标志位
    jnc no_ia_32e                       ; 不支持就到 no_ia_32e 处执行

    mov bp, arch0
    mov cx, arch1 - arch0
    mov bl, 0x07                        ; 黑底白字
    call put_string_by_bios

    ; 显示处理器商标信息
    mov eax, 0x80000000 
    cpuid
    cmp eax, 0x80000004
    jb .no_brand

    mov eax, 0x80000002
    cpuid
    mov [brand + 0x00], eax
    mov [brand + 0x04], ebx
    mov [brand + 0x08], ecx
    mov [brand + 0x0c], edx

    mov eax, 0x80000003
    cpuid
    mov [brand + 0x10], eax
    mov [brand + 0x14], ebx
    mov [brand + 0x18], ecx
    mov [brand + 0x1c], edx

    mov eax, 0x80000004
    cpuid
    mov [brand + 0x20], eax
    mov [brand + 0x24], ebx
    mov [brand + 0x28], ecx
    mov [brand + 0x2c], edx

    mov bp, brand_mag
    mov cx, cpu_addr - brand_mag
    mov bl, 0x07
    call put_string_by_bios

    ; 第五章再回来填坑----
.no_brand:
    ; 获取当前系统的物理内存布局信息(使用 int 0x15, E820 功能。俗称 E820 内存)
    push es 

    mov bx, SDA_PHY_ADDR >> 4               ; 切换到系统数据区
    mov es, bx 
    mov word [es:0x16], 0
    xor ebx, ebx                            ; 首次调用 int 0x15 时必须为 0
    mov di, 0x18                            ; 系统数据区内的偏移

.mlookup:
    mov eax, 0xe820
    mov ecx, 32
    mov edx, "PAMS"
    int 0x15
    add di, 32
    inc word [es:0x16]
    or ebx, ebx
    jnz .mlookup

    pop es
    ; 第五章再回来填坑----
    ; 获取存储处理器的物理/虚拟地址尺寸信息
    mov eax, 0x80000000                     
    cpuid
    cmp eax, 0x80000008
    mov ax, 0x3024                          ; 设置默认的处理器物理/逻辑地址位数 36(0x24) 和 48(0x30)
    jb .no_plsize

    mov eax, 0x80000008                     ; 执行后, ax 中 0-7 位(al)是物理地址尺寸, 8-15 位(ah)是虚拟地址尺寸
    cpuid

.no_plsize:
    ; 保存物理和虚拟地址尺寸到系统数据区
    push ds 
    mov bx, SDA_PHY_ADDR >> 4               ; 切换到系统数据区
    mov ds, bx 
    mov word [0], ax                        ; 记录处理器的物理/虚拟地址尺寸
    pop ds 

    ; 准备显示存储器的物理地址尺寸信息
    push ax                                 ; 备份 ax

    and ax, 0x00ff                          ; 只要 al 中的物理地址
    mov si, 2
    mov bl, 10

.re_div0:
    div bl                                  ; 16 位除法, 商在 al 中, 余数在 ah 里
    add ah, 0x30                            ; ASCII 码
    mov [paddr + si], ah                    ; 低位在高地址
    dec si 
    add ax, 0x00ff
    jnz .re_div0

    ; 准备显示处理器的虚拟地址尺寸信息
    pop ax 

    shr ax, 8                               ; 将虚拟地址移到 al 重复上边的逻辑
    mov si, 2
    mov bl, 10
.re_div1:
    div bl 
    add ah, 0x30 
    mov [laddr + si], ah 
    dec si 
    add ax, 0x00ff
    jnz .re_div1

    ; 显示处理器的物理/虚拟地址尺寸信息
    mov bp, cpu_addr
    mov cx, protect - cpu_addr
    mov bl, 0x07   
    call put_string_by_bios

    ; 以下开始进入保护模式, 为 IA-32e 模式做必要的准备工作
    mov ax, GDT_PHY_ADDR >> 4               ; 计算 GDT 所在的逻辑段地址
    mov ds, ax 

    ; 跳过 0# 号描述符的槽位, 处理器规定 0# 号描述符为空
    
    ; 创建 1# 描述符, 保护模式下的代码段描述符
    mov dword [0x08], 0x0000ffff            ; 基地址为0, 界限0xFFFFF, DPL=00, 4KB 粒度, 代码段描述符, 向上扩展
    mov dword [0x0c], 0x00cf9800
    
    ; 创建 2# 描述符, 保护模式下的数据段和堆栈段描述符
    mov dword [0x10], 0x0000ffff            ; 基地址为0, 界限0xFFFFF, DPL=00, 4KB 粒度, 数据段描述符, 向上扩展
    mov dword [0x14], 0x00cf9200

    ; 创建 3# 描述符, 64 位模式下的代码段描述符。为进入 64 位提前作准备, 其 L 位是 1
    mov dword [0x18], 0x0000ffff            ; 基地址为0, 界限0xFFFFF, DPL=00, 4KB 粒度, L=1, 代码段描述符, 向上扩展
    mov dword [0x1c], 0x00af9800

    ; 记录 GDT 的基地址和界限值
    mov ax, SDA_PHY_ADDR >> 4               ; 切换到系统数据区
    mov ds, ax  

    mov word[2], 0x1f                       ; 描述符表的界限
    mov dword[4], GDT_PHY_ADDR              ; GDT 的线性基地址

    ; 加载描述符表寄存器 GDTR
    lgdt [2]

    in al, 0x92                             ; 南桥芯片内的端口
    or al, 0000_0010B
    out 0x92, al                            ; 打开处理器的第 21 根地址线 A20

    cli                                     ; 关闭中断

    mov eax, cr0                            ; 设置控制寄存器 CR0 的 PE 位, 将处理器从实模式切换到保护模式。
    or eax, 1
    mov cr0, eax 

    ; 以下进入保护模式
    jmp 0x0008: dword LDR_PHY_ADDR + flush  ; 0x0008 是 16 位描述符选择子, 从 GDT 中选择第二个描述符。jmp 后清流水线并串行化处理器, 跳转到 flush

    [bits 32]
flush:
    mov eax, 0x0010                         ; 加载数据段(4GB)选择子
    mov ds, eax
    mov es, eax
    mov fs, eax
    mov gs, eax
    mov ss, eax  
    mov esp, 0x7c00                         ; 堆栈指针

    ; 显示信息, 在保护模式下位进入 IA-32e 模式做准备
    mov ebx, LDR_PHY_ADDR + protect
    call put_string_flat32

    ; 以下加载系统核心程序
    mov edi, CORE_PHY_ADDR

    mov eax, COR_START_SECTOR
    mov ebx, edi                            ; 起始地址
    call read_hard_disk_0                   ; 读取程序起始第一扇区

    ; 判断程序大小
    mov eax, [edi]                          ; 内核程序大小
    xor edx, edx 
    mov ecx, 512                            ; 每个扇区大小为 512
    div ecx                                 ; 商存储在 eax 中, 余数存储在 edx 中

    ; 处理长度 < 512 字节的情况
    or eax, eax 
    jz pge
    ; 处理长度 >= 512 字节的情况
    or edx, edx 
    jnz @1
    dec eax 
    or eax, eax                             ; 正好为 512 时, 单独处理
    jz pge
@1:
    ; 读取剩余扇区
    mov ecx, eax                            ; 循环次数
    mov eax, COR_START_SECTOR
    inc eax 
@2:
    call read_hard_disk_0
    inc eax
    loop @2

pge:
    ; 回填内核加载地址的物理地址到内核程序头部
    mov dword [CORE_PHY_ADDR + 0x08], CORE_PHY_ADDR
    mov dword [CORE_PHY_ADDR + 0x0c], 0

    ; 创建 4 级分页系统, 只包含基本部分, 覆盖低端 1 MB物理内存
    mov ebx, PML4_PHY_ADDR                  ; 找个地方存四级页表

    ; 4 级页表清零
    mov ecx, 1024
    xor esi, esi 
.cls0:
    mov dword [ebx + esi], 0
    add esi, 4
    loop .cls0

    ; 在 4 级页表内最后一项存放自身地址, 这样可以通过虚拟地址访问表中最后一项来获取页表的真实地址
    mov dword [ebx + 511 * 8], PML4_PHY_ADDR | 3    ; 添加属性
    mov dword [ebx + 511 * 8 + 4], 0

    ; 映射虚拟地址与物理地址的低端 2 MB, 确保开启分页后也可以正常访问, 即地址经过页表转换后不变。
    ; 0x0000000000000000--0x00000000001FFFFF 低 48 位按 9 9 9 9 12 分割进行四级分页查表。而高 16 位无效, 填充符号位
    mov dword [ebx + 0 * 8], PDPT_PHY_ADDR  | 3     ; 添加属性
    mov dword [ebx + 0 * 8 + 4], 0

    ; 将页目录指针表中的内容清 0
    mov PDPT_PHY_ADDR

    mov ecx, 1024
    xor esi, esi 
.cls1:
    mov dword [ebx + esi], 0
    add esi, 4
    loop .cls1

    ; 套娃, 创建下一级页表
    mov dword [ebx + 0 * 8], PDT_PHY_ADDR | 3
    mov dword [ebx + 0 * 8 + 4], 0

    ; 清 0
    mov ebx PDT_PHY_ADDR

    mov ecx, 1024
    xor esi, esi
.cls2:
    mov dword [ebx + esi], 0
    add esi, 4
    loop .cls2

    ; 在页目录表内创建与低端 2MB 对应的表项
    mov dword [ebx + 0 * 8], 0 | 0x83       ; 位 7、R/W 位、P 位是 1, 其他全是 0
    mov dword [ebx + 0 * 8 + 4], 0

    ; 将物理内存的低端 2MB 映射到线性地址空间的高端, 内核处于高地址, 要做一次重复映射。0xFFFF800000000000--0xFFFF8000001FFFFF
    mov ebx, PML4_PHY_ADDR

    mov dword [ebx + 256 * 8], PDPT_PHY_ADDR | 3 ; 页目录表
    mov dword [ebx + 256 * 8 + 4], 0

    ; 因为要为每个进程都给予一个独立的 4 级头表(可以理解为指针数组), 而内核空间是所有进程共享的, 要在每个进程独立
    ; 的 4 级头表中内核公共部分填入一样的数据。页表机制的一个特点是 就是动态分配, 用时间换空间, 为了避免此特性使
    ; 每个进程不停的去同步 4 级头表中内核公共部分, 索性直接将 4 级头表中内核公共部分全部预分配好。详细解释见书中 135 页。
    mov eax, 257
    mov edx, COR_PDPT_ADDR | 3
.fill_pml4:
    mov dword [ebx + eax * 8], edx 
    mov dword [ebx + eax * 8 + 4], 0
    add edx, 0x1000
    inc eax 
    cmp eax, 511
    jb .fill_pml4

    ; 将预分配的页目录指针表全部清零
    mov eax, COR_PDPT_ADDR
.zero_pdpt:
    mov dword [eax], 0
    add eax, 4
    cmp eax, COR_PDPT_ADDR + 0x1000 * 254
    jb .zero_pdpt

    ; 将 cr3 寄存器指向 4 级头表
    mov eax, PML4_PHY_ADDR
    mov cr3, eax 

    ; 开启物理扩展 PAE
    mov eax, cr4 
    bts eax, 5                              ; 位测试并置位
    mov cr4, eax 

    ; 设置型号专属寄存器 IA32_EFER.LME, 允许 IA_32e 模式
    mov ecx, 0x0c0000080                    ; 指定型号专属寄存器 IA32_EFER
    rdmsr
    bts eax, 8                              ; 设置 LME 位
    wrmsr 

    ; 开启分页功能
    mov eax, cr0 
    bts eax, 31                             ; 置位 cr0.PG
    mov cr0, eax 

    ; 打印 IA_32e 激活信息
    mov ebx, ia_32e + LDR_PHY_ADDR
    call put_string_flat32

    ; 通过原返回的方式进入 64 位模式内核
    push word CORE_CODE64_SEL
    mov eax, dword [CORE_PHY_ADDR + 4]
    add eax, CORE_PHY_ADDR
    push eax 
    retf                                    ; 压入 GDT 选择子和地址

; ------------------------------------------------------------
; put_string_flat32
; 功能: 显示 0 终止的字符串并移动光标。只运行在32位保护模式下, 且使用平坦模型。
; 输入: EBX=字符串的线性地址
; ------------------------------------------------------------
put_string_flat32:
    push ebx 
    push ecx 
.getc:
    mov cl, [ebx]
    or cl, cl                               ; 检测串结束标志 0
    jz .exit                                
    call put_char
    int ebx 
    jmp .getc

.exit:
    pop ecx 
    pop ebx 

    ret 

; ------------------------------------------------------------
; put_char
; 功能: 在当前光标处显示一个字符, 并推进光标, 仅用于段内调用
; 输入: CL=字符ASCII码
; ------------------------------------------------------------
put_char:
    pushad 

    mov dx, 0x3d4                           ; 0x3d4 是 VGA 显卡的索引寄存器端口地址, 用于指定要操作的显卡寄存器。
    mov al, 0xe                             ; 0xe 是显卡的光标位置寄存器的索引值, 用于读取光标的高字节位置。
    out dx, al                              ; 将 0xe 输出到端口 0x3d4, 
    inc dx                                  ; 0x3d5 是显卡的数据寄存器端口地址, 用于读取或写入显卡寄存器的实际数据。
    in al, dx                               ; 从端口 0x3d5 读取数据到 al, 读取了光标位置的高字节

    mov ah, al                              ; 存入 ah 

    dec dx                                  ; 同上, 再获取低字节
    mov al, 0x0f                            ; 0x0f 是显卡的光标位置寄存器的索引值, 用于读取光标的低字节位置。
    out dx, al 
    inc dx 
    in al, dx 

    mov bx, ax                              ; 此时 bx 中存储了字符的数目, 一个字符占两个字节
    and edx, 0x0000ffff

    cmp cl, 0x0d                            ; 回车符?
    jnz .put_0a                             ; 不是回车符检查是不是换行符(0x0a)

    mov ax, bx                              ; 处理回车符
    mov bl, 80                              ; 行宽 80
    div bl 
    mul bl                                  ; 移到本行起始
    mov bx, ax 
    jmp .roll_screen

.put_0a:
    cmp cl, 0x0a                            ; 换行符?
    jnz .put_other

    add bx, 80                              ; 处理换行符
    jmp .roll_screen

.put_other:                                 ; 显示字符
    shl bx, 1                               ; 在文本模式下, 显存中每个字符占用 2 个字节, 左移 1 位相当于将 bx 的值乘以 2, 从而将光标位置从字符索引转换为显存中的字节偏移量。
    mov [0xb8000 + ebx], cl                 ; 0xb800:0000(0xb8000) 是显存的起始地址

    shr bx, 1                               ; 将光标位置移到下一个字符
    inc bx      

.roll_screen:
    cmp bx, 2000                            ; 超出屏幕外? 
    jl .set_cursor                          ; 设置光标

    ; 滚屏处理
    push ebx                                ; 保存光标位置               

    cld                                     ; 清除方向标志
    mov esi, 0xb80a0                        ; 0xb80a0 是显存中第 2 行字符的起始地址。源地址
    mov edi, 0xb8000                        ; 0xb8000 是显存起始地址。目标地址
    mov ecx, 960                            ; 960 == 24 x 80 x 2 / 4, 滚屏操作需要将第 2 行到第 25 行的内容向上移动一行, 覆盖第 1 行的内容。
    rep movsd                               ; rep movsd 会根据 ecx 的值重复移动数据, 直到 ecx 为 0。每次移动 4 个字节
    
    ; 清除屏幕最后一行
    mov ebx, 3840                           ; 3840 == 24 x 80 x 2, 设置光标位置为屏幕最后一行的起始位置。
    mov ecx, 80                             ; ecx 是循环次数

.cls:
    mov word[0xb8000 + ebx], 0x0720         ; 0x0720 是空格字符, 黑色背景
    add ebx, 2
    loop .cls 

    pop ebx                                 ; 恢复光标
    sub ebx, 80                             ; 上移一行

.set_cursor:                                ; 设置光标
    mov dx, 0x3d4
    mov al, 0x0e
    out dx, al
    inc dx 
    mov al, bh 
    out dx, al 

    dec dx 
    mov al, 0x0f
    out dx, al 
    inc dx 
    mov al, bl 
    out dx, al 

    popad 
    ret 

; ------------------------------------------------------------
; read_hard_disk_0
; 功能: 从硬盘中读取一个扇区
; 输入: eax=逻辑扇区号, ebx=目标缓冲区地址
; 返回: ebx = ebx + 512
; ------------------------------------------------------------
read_hard_disk_0:
    push eax
    push ecx
    push edx 

    push eax 

    mov dx, 0x1f2                           ; 0x1f2 是硬盘控制器的一个端口地址, 用于指定要读取的扇区数量。
    mov al, 1
    out dx, al                              ; 将 1 写入到硬盘控制器的端口 0x1f2, 告诉硬盘控制器接下来要读取一个扇区。

    inc dx                                  ; 0x1f3
    pop eax 
    out dx, al                              ; LBA 地址 7 ~ 0

    inc dx                                  ; 0x1f4
    mov cl, 8
    shr eax, cl 
    out dx, al                              ; LBA 地址 15 ~ 8

    inc dx                                  ; 0x1f5
    shr eax, cl 
    out dx, al                              ; LBA 地址 23 ~ 16

    inc dx                                  ; 0x1f6
    shr eax, cl 
    or al, 0xe0                             ; 第一硬盘
    out dx, al                              ; LBA 地址 27 ~ 24

    inc dx                                  ; 0x1f7
    mov al, 0x20    
    out dx, al                              ; 读命令

.waits:
    in al, dx 
    test al, 8
    jz .waits                               ; 忙或数据还没准备好, 循环查询

    mov ecx, 256                            ; 总共要读取的字数, 循环次数
    mov dx, 0x1f0

.readw:
    in ax, dx                               ; 循环去读硬盘数据写入指定内存
    mov [ebx], ax 
    add ebx, 2
    loop .readw

    pop edx 
    pop ecx 
    pop eax 

    ret 

SECTION trail
    ldr_end