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
; print_string
; 功能: 在光标当前位置按指定颜色打印字符串
; 输入: bp = 字符串地址, cx = 长度, bl = 颜色属性
; 输出: 无(光标自动后移)
; ------------------------------------------------------------
print_string:
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
    call print_string

    cli
    hlt


start:
    mov bp, msg0
    mov cx, arch0 - msg0
    mov bl, 0x4f                        ; 红底亮白字
    call print_string

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
    call print_string

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
    call print_string

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
    call print_string

    ; 以下开始进入保护模式, 为 IA-32e 模式做必要的准备工作
    mov ax, GDT_PHY_ADDR >> 4               ; 计算 GDT 所在的逻辑段地址
    mov ds, ax 

    

SECTION trail
    ldr_end