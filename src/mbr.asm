; 主引导扇区程序

%include "../common/global_defs.asm"

SECTION mbr vstart=0x00007c00
    xor ax, ax
    mov ds, ax 
    mov es, ax 
    mov ss, ax 
    mov sp, 0x7c00

    ; 装入内核加载器

    ; 为了使用 BIOS 扩展硬盘读功能, 构造所需参数, 见书中 102 页
    ; 构造地址结构
    push dword 0                            ; 压入起始的逻辑扇区号, 8 字节, 分两个 dword, 小端序
    push dword LDR_START_SECTOR
    push word LDR_PHY_ADDR >> 4             ; 压入数据缓冲区逻辑段地址
    push word 0                             ; 压入数据缓冲区段内偏移
    push word 0x0001                        ; 本次传输的扇区数
    push word 0x0010                        ; 保留位固定为 0 以及当前地址结构尺寸
    ; 其他参数
    mov si, sp
    mov ah, 0x42                            ; 对应 int 0x13 扩展读功能
    mov dl, 0x80                            ; 主盘, 0x80 为第一硬盘
    int 0x13                                ; 成功则 CF=0, AH=0; 失败则 CF=1, AH=错误代码
    mov bp, msg0
    mov di, msg1 - msg0
    jc go_err                               ; 读写磁盘失败, 显示信息并停止运行

    push ds 

    mov cx, LDR_PHY_ADDR >> 4               ; 切换到加载器所在的段地址
    mov ds, cx 
    cmp dword [0], "lino"                   ; 检查加载器有效标志, 加载器魔数
    mov bp, msg1
    mov di, mend - msg1
    jnz go_err                              ; 加载器不存在, 显示信息并停止运行

    ; 加载器程序长度处理
    mov eax, [4]                            ; 获取整个程序的大小
    xor edx, edx                            ; 将 edx 寄存器清零
    mov ecx, 512
    div ecx                                 ; 被除数高位在 edx 中, 低位在 eax 中, 除数是 ecx, 最后的商在 eax 中, 余数在 edx 中
    ; 处理长度 < 512 字节的情况
    or eax, eax                             
    jz go_ldr
    ; 处理长度 >= 512 字节的情况
    or edx, edx                             ; 判读 edx 是否为 0, 不为零, 说面 eax 是少一的, 因为最开始已经读了一个扇区, 正好弥补这里
    jnz @1                                
    dec eax                                 ; edx 为 0, 即没有余数, 反而要将 eax 中的总扇区数减一
    or eax, eax                             ; 正好等于 512 时, 单独处理
    jz go_ldr
@1:
    ; 读取剩余扇区
    pop ds                                  

    mov word [si + 2], ax                   ; 重新设置要读取的逻辑扇区数
    mov word [si + 4], 512                  ; 重新设置下一个段内偏移量
    inc dword [si + 8]                      ; 起始逻辑扇区号加一
    mov ah, 0x42                            ; 读取
    mov dl, 0x80
    inc 0x13

    mov bp, msg0
    mov di, msg1 - msg0
    jc go_err                               ; 读写磁盘失败, 显示信息并停止运行

go_ldr:
    mov sp, 0x7c00                          ; 恢复栈, 之前用来存 int 0x13 需要的地址结构

    mov ax, LDR_PHY_ADDR >> 4
    mov ds, ax 
    mov es, ax 

    push ds                                 
    push word [8]                           ; 8 字节偏移出存放内核加载器的入口点地址
    retf                                    ; 进入加载器执行, 用 retf 来改变 cs 与 ip 寄存器的值。

go_err:
    mov ah, 0x03                            ; 获取光标位置 详细解释见书中 106 页
    mov bh, 0x00
    int 0x10

    mov cx, di 
    mov ax, 0x1301                          ; 屏幕写字符串, 光标移动
    mov bh, 0
    mov bl, 0x07                            ; 常规黑底白字
    int 0x10

    cli 
    hlt

    msg0            db "Disk error.", 0x0d, 0x0a
    msg1            db "Missing loader.", 0x0d, 0x0a
    mend:

    times 512 - 2 - ($ - $$) db 0
    db 0x55, 0xaa