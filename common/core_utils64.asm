; 内核通用代码

; 在多处理器环境中使用时, 需要在内核程序中定义宏 __MP__

%include "./common/global_defs.asm"

	[bits 64]

; ------------------------------------------------------------
; put_string64
; 功能: 显示 0 终止的字符串并移动光标
; 输入: rbx=字符串的线性地址
; ------------------------------------------------------------
%ifdef __MP__
_prn_str_locker dq 0
%endif

put_string64:
	push rbx 
	push rcx 

	pushfq 
	cli 
%ifdef __MP__
	SET_SPIN_LOCK rcx, qword [rel _prn_str_locker]		; 上锁
%endif 

.getc:
	mov cl, [rbx]
	or cl, cl 							; 检查是不是 0
	jz .exit 							; 如果是 0 跳转到退出代码
	call put_char 
	inc rbx 
	jmp .getc

.exit:
%ifdef __MP__ 
	mov qword [rel _prn_str_locker], 0					; 释放锁
%endif
	popfq

	pop rcx 
	pop rbx 

	ret 
	
; ------------------------------------------------------------
; put_char
; 功能: 在屏幕上的当前光标处显示一个字符并推进光标(ldr.asm 中 put_char 的 64 位版本)
; 输入: cl=字符ASCII码
; ------------------------------------------------------------
put_char:
	push rax 
	push rbx 
	push rcx 
	push rdx 
	push rsi 
	push rdi 

	; 获取光标位置
	mov dx, 0x3d4
	mov al, 0x0e 
	out dx, al 
	inc dx 
	in al, dx 								; 高字
	mov ah, al 

	dec dx 
	mov al, 0x0f 
	out dx, al 
	inc dx 
	in al, dx 								; 低字
	mov bx, ax 								; 此时 bx 中存储了字符的数目, 一个字符占两个字节
	and rbx, 0x000000000000ffff 			; 准备使用 64 位寻址方式访问显存

	cmp cl, 0x0d							; 回车符?
	jnz .put_0a
	mov ax, bx 
	mov bl, 80
	div bl 
	mul bl 									; 移到本行起始
	mov bx, ax 	
	jmp .set_cursor

.put_0a:
	cmp cl, 0x0a 							; 换行符?
	jnz .put_other
	add bx, 80								; 平移一行
	jmp .roll_screen

.put_other:						
	shl bx, 1								; 转换成字节数
	mov rax, UPPER_TEXT_VIDEO
	mov [rax + rbx], cl 					; 写入字符

	shr bx, 1								; 转回字符数
	inc bx 

.roll_screen:
	cmp bx, 2000							; 光标超出屏幕? 滚屏
	jl .set_cursor 
	
	push bx 

	cld 									; 清除方向标志位
	mov rsi, UPPER_TEXT_VIDEO + 0xa0		; 源地址
	mov rdi, UPPER_TEXT_VIDEO				; 目标地址
	mov rcx, 480							; 480 == 24 x 80 x 2 / 8。前 24 行向上平移一行
	rep movsq								

	mov bx, 3840							; 24 x 80 x 2。清除最后一行
	mov rcx, 80
.cls:
	mov rax, UPPER_TEXT_VIDEO
	mov word [rax + rbx], 0x0720
	add bx, 2 
	loop .cls 

	pop bx 									; 考虑换行符
	sub bx, 80

.set_cursor:
	mov dx, 0x3d4
	mov al, 0x0e 
	out dx, al 
	inc dx 									; 0x3d5
	mov al, bh 
	out dx, al 

	dec dx 									; 0x3d4
	mov al, 0x0f 
	out dx, al 
	inc dx 									; 0x3d5
	mov al, bl 
	out dx, al 

	pop rdi 
	pop rsi 
	pop rdx 
	pop rcx 
	pop rbx 
	pop rax 

	ret 

; ------------------------------------------------------------
; put_cstringxy64
; 功能: 在指定位置用指定颜色显示 0 终止的字符串，只适用于打印图形字符。由于各程序打印时的坐标位置不同，互不干扰，不需要加锁和互斥。
; 输入: rbx=字符串首地址, dh=行, dl=列, r9b=颜色属性
; ------------------------------------------------------------
%ifdef __MP__ 
_prnxy_locker dq 0
%endif 

put_cstringxy64:
	push rax 
	push rbx 
	push rcx 
	push rdx 
	push r8 

	; 指定坐标位置在显存内的偏移量
	mov al, dh 
	mov ch, 160									; 每行 80 个字符, 占用 160 字节
	mul ch 
	shl dl, 1									; 每个字符占两字节
	and dx, 0x00ff
	add ax, dx 									; 得到相应显存偏移
	and rax, 0x000000000000ffff

	pushfq										; 将 RFLAGS 寄存器的全部 64 位标志位压入当前栈顶
	cli 

%ifdef __MP__									; 读写显存时加锁
	SET_SPIN_LOCK r8, qword [rel _prnxy_locker]
%endif 

	mov r8, UPPER_TEXT_VIDEO					; 显存起始线性地址
.nextc:
	mov dl, [rbx]								; 获取将要显示的字符
	or dl, dl 
	jz .exit 
	mov byte [r8 + rax], dl 					; 字符内容
	mov byte [r8 + rax + 1], r9b 				; 字符颜色
	inc rbx 
	add rax, 2
	jmp .nextc
.exit:
	xor r8, r8 

%ifdef __MP__									; 读写显存时释放锁
	mov qword [rel _prnxy_locker], 0
%endif 

	popfq 

	pop r8 
	pop rdx 
	pop rcx 
	pop rbx 
	pop rax 

	ret 

; ------------------------------------------------------------
; make_interrupt_gate
; 功能: 创建 64 位的中断门
; 输入: rax=处理程序的线性地址
; 输出: rdi 与 rsi 组成中断门(中断门、陷阱门格式见书中 148 页)
; ------------------------------------------------------------
make_interrupt_gate:
	mov rdi, rax 
	shr rdi, 32 						; 门的高 64 位, 其中高 32 位是保留

	push rax 							; 借助栈构造, 先压入完整 rax, 也就是门的低 64 位, 在对其修改
	mov word [rsp + 2], CORE_CODE64_SEL	; 填入选择子
	mov [rsp + 4], eax 					; 填入线性地址 31~16 位
	mov word [rsp + 4], 0x8e00			; 填入属性, P=1, TYPE=64 的中断门, 覆盖填入
	pop rsi 

	ret 								; 可以参考书中 155 页的图

; ------------------------------------------------------------
; make_tss_descriptor
; 功能: 创建 64 位的 TSS 描述符
; 输入: rax=TSS 的线性地址
; 输出: rdi:rsi=TSS 描述符(LDT, TSS 描述符格式见书中 200 页)
; ------------------------------------------------------------
make_tss_descriptor:
	push rax 

	mov rdi, rax 
	shr rdi, 32							; 得到门高 64 位, 存在 rdi 中

	push rax 							; 借助栈构造, 先压入完整 rax, 也就是门的低 64 位, 在对其修改
	shl qword [rsp], 16 				; 将线性地址 23~0 位移到正确位置
	mov word [rsp], 104					; 填入段界限标准长度
	mov al, [rsp + 5]
	mov [rsp + 7], al 					; 将线性地址 31~24 位移到正确位置
	mov byte [rsp + 5], 0x89 			; P=1, DPL=0, TYPE=0b1001(64 位 TSS)
	mov byte [rsp + 6], 0				; G, 0, 0, AVL, limit
	pop rsi								; 门低 64 位

	pop rax 

	ret 

; ------------------------------------------------------------
; mount_idt_entry
; 功能: 在中断描述符表 IDT 中安装门描述符
; 输入: r8=中断向量, rdi 与 rsi 组成中断门
; ------------------------------------------------------------
mount_idt_entry:
	push r8
	push r9 

	shl r8, 4 							; 中断号乘以 16 得到表内偏移, 每个中断门 16 字节大小
	mov r9, UPPER_IDT_LINEAR			; 中断描述符表的高端地址
	mov [r9 + r8], rsi 
	mov [r9 + r8 + 8], rdi 

	pop r9 
	pop r8 

	ret  

; ------------------------------------------------------------
; init_8259
; 功能: 初始化8259中断控制器，包括重新设置向量号
; ------------------------------------------------------------
init_8259:
	push rax

	mov al, 0x11
	out 0x20, al                    	; ICW1: 边沿触发/级联方式
	mov al, 0x20
	out 0x21, al  						; ICW2: 起始中断向量（避开前31个异常的向量）
	mov al, 0x04
	out 0x21, al  						; ICW3: 从片级联到 IR2
	mov al, 0x01
	out 0x21, al                  		; ICW4: 非总线缓冲，全嵌套，正常 EOI

	mov al, 0x11
	out 0xa0, al                  		; ICW1: 边沿触发/级联方式
	mov al, 0x28
	out 0xa1, al                  		; ICW2: 起始中断向量-->0x28
	mov al, 0x02
	out 0xa1, al                  		; ICW3: 从片识别标志，级联到主片 IR2
	mov al, 0x01
	out 0xa1, al                  		; ICW4: 非总线缓冲，全嵌套，正常 EOI

	pop rax
	ret

; ------------------------------------------------------------
; read_hard_disk_0
; 功能: 从硬盘读取一个逻辑扇区
; 输入: rax=逻辑扇区号, rbx=目标缓冲区线性地址
; 输出: rbx=rbx+512
; ------------------------------------------------------------
%ifdef __MP__
_read_hdd_locker dq 0						
%endif

read_hard_disk_0:
	push rax 
	push rcx 
	push rdx 
	pushfq

	cli 

%ifdef __MP__
	SET_SPIN_LOCK rdx, qword [rel _read_hdd_locker]
%endif

	push rax 

	mov dx, 0x1f2 								; 0x1f2
	mov al, 1
	out dx, al 									; 读取扇区数

	inc dx 										; 0x1f3 
	pop rax 
	out dx, al 									; LBA 地址 7~0

	mov cl, 8 

	inc dx 										; 0x1f4
	shr rax, cl 
	out dx, al 									; LBA 地址 15~8

	inc dx 										; 0x1f5
	shr rax, cl 
	out dx, al 									; LBA 地址 23~16

	inc dx 										; 0x1f6
	shr rax, cl 
	or al, 0xe0 								; 第一硬盘, LBA 地址 27~24
	out dx, al 

	inc dx 										; 0x1f6
	mov al, 0x20 								; 读命令
	out dx, al 

.waits:
	in al, dx 
	test al, 8
	jz .waits
	; 不忙且硬盘已经准备好传输数据
	mov rcx, 256								; 总共要读的字数=2字节
	mov dx, 0x1f0 
.readw:
	in ax, dx 
	mov [rbx], ax 
	add rbx, 2
	loop .readw 

%ifdef __MP__
	mov qword [rel _read_hdd_locker], 0
%endif

	popfq
	pop rdx 
	pop rcx 
	pop rax 

	ret 

; ------------------------------------------------------------
; allocate_a_4k_page
; 功能: 分配一个 4KB 的页
; 输出: rax=页的物理地址
; ------------------------------------------------------------	
_page_bit_map times 2 * 1024 / 4 / 8 db 0xff 		; 对应物理内存前 512 页(2MB), 见书中 193 页
	times (PHY_MEMORY_SIZE - 2) * 1024 / 4 / 8 db 0	; 存放后续的页面
_page_map_len equ $ - _page_bit_map

allocate_a_4k_page:
	xor rax, rax 
.b1:
	lock bts [rel _page_bit_map], rax 				; 多处理器需要 lock, 这是一个指令前缀，用于将随后的指令变成原子操作
	jnc .b2 
	inc rax 
	cmp rax, _page_map_len * 8
	jl .b1 

	; 对我们这个简单的系统来说，通常不存在页面不够分配的情况。对于一个流行的系统来说, 
	; 如果页面不够分配，需要在这里执行虚拟内存管理，即，回收已经注销的页面，或者执行页面的换入和换出。
.b2:
	shl rax, 12										; rax 是位数, 转换为内存要乘 4098

	ret 

; ------------------------------------------------------------
; lin_to_lin_of_pml4e
; 功能: 返回指定的线性地址所对应的 4 级头表项的线性地址
; 输入: r13=线性地址
; 输出: r14=对应的 4 级头表项的线性地址
; ------------------------------------------------------------
lin_to_lin_of_pml4e:
	push r13 

	mov r14, 0x0000_ff80_0000_0000 			; 保留 4 级头表索引部分
	and r13, r14 	
	shr r13, 36								; 右移到低位, 相当于偏移 = 索引 * 8

	; 这个利用了递归映射, 还记得在 ldr.asm 中我们将 4 级头表中最后一个项填入了其本身的地址, 
	; 而 0xffff_ffff_ffff_f000 这个线性地址前缀会一直访问最后一个表项, 得到的也一直是 4 级头表的地址
	mov r14, 0xffff_ffff_ffff_f000			; 访问 4 级头表所用的地址前缀
	add r14, r13 							

	pop r13 

	ret 

; ------------------------------------------------------------
; lin_to_lin_of_pdpte
; 功能: 返回指定的线性地址所对应的页目录指针项的线性地址
; 输入: r13=线性地址
; 输出: r14=对应的页目录指针项的线性地址
; ------------------------------------------------------------
lin_to_lin_of_pdpte:
	push r13 

	mov r14, 0x0000_ffff_c000_0000			; 保留 4 级头表索引和页目录指针表索引部分
	and r13, r14 
	shr r13, 27								

	; 同上
	mov r14, 0xffff_ffff_ffe0_0000
	add r14, r13 

	pop r13

	ret 

; ------------------------------------------------------------
; lin_to_lin_of_pdte
; 功能: 返回指定的线性地址所对应的页目录项的线性地址
; 输入: r13=线性地址
; 输出: r14=对应的页目录项的线性地址
; ------------------------------------------------------------
lin_to_lin_of_pdte:
	push r13 

	mov r14, 0x0000_ffff_ffe0_0000			; 保留 4 级头表索引、页目录指针表索引和页目录表
	and r13, r14 
	shr r13, 18								

	; 同上
	mov r14, 0xffff_ffff_c000_0000
	add r14, r13 

	pop r13

	ret 

; ------------------------------------------------------------
; lin_to_lin_of_pte
; 功能: 返回指定的线性地址所对应的页表项的线性地址
; 输入: r13=线性地址
; 输出: r14=对应的页表项的线性地址
; ------------------------------------------------------------
lin_to_lin_of_pte:
	push r13 

	mov r14, 0x0000_ffff_ffff_f000			; 保留 4 级头表、页目录指针表、页目录表和页表的索引部分
	and r13, r14 
	shr r13, 9								

	; 同上
	mov r14, 0xffff_ff80_0000_0000
	add r14, r13 

	pop r13

	ret 


; ------------------------------------------------------------
; find_pte_for_laddr
; 功能: 为指定的线性地址寻找到页表项线性地址
; 注意: 不保证线程安全, 如果需要在外部加锁, 关中断. 使用了 rcx, rax, r14 寄存器, 但不负责维护内容不变, 如果需要在外部 push, pop
; 输入: r13=线性地址
; 输出: r14=页表项线性地址
; ------------------------------------------------------------
find_pte_for_laddr:
	; 四级头表一定存在, 检查对应地址的四级头表项是否存在
	call lin_to_lin_of_pml4e							; 得到四级头表项的线性地址
	test qword [r14], 1									; 看 P 位是否为 1 判断表项是否存在
	jnz .b0

	; 创建并安装该线性地址所对应的 4 级头表项(创建页目录指针表)
	call allocate_a_4k_page								; 分配一个页作为页目录指针表
	or rax, 0x07										; rax 是分配页的物理地址, 添加属性位 U/S=R/W=P=1
	mov [r14], rax 										; 在 4 级头表中登记 4 级头表项

	; 清空刚分配的页目录指针表
	call lin_to_lin_of_pdpte
	shr r14, 12
	shl r14, 12											; 得到页目录指针表的线性地址, 低 12 位是页目录指针项在页目录指针表内的偏移
	mov rcx, 512
.cls0:
	mov qword [r14], 0
	add r14, 8
	loop .cls0

.b0:
	; 检查该线性地址对应的页目录指针项是否存在
	call lin_to_lin_of_pdpte 							; 得到页目录指针项的线性地址
	test qword [r14], 1									; 看 P 位是否为 1 判断表项是否存在
	jnz .b1 

	; 创建并安装该线性地址对应的页目录指针项
	call allocate_a_4k_page								; 分配一个页作为页目录表
	or rax, 0x07
	mov [r14], rax 

	; 清空刚分配的页目录表
	call lin_to_lin_of_pdte 
	shr r14, 12
	shl r14, 12 
	mov rcx, 512 
.cls1:
	mov qword [r14], 0
	add r14, 8
	loop .cls1 

.b1:
	; 检查该线性地址对应的页目录指针项是否存在
	call lin_to_lin_of_pdte 
	test qword [r14], 1
	jnz .b2 

	; 创建并安装该线性地址对应的页目录项, 即分配页表
	call allocate_a_4k_page
	or rax, 0x07
	mov [r14], rax 

	; 清空刚分配的页表
	call lin_to_lin_of_pte 
	shr r14, 12
	shl r14, 12
	mov rcx, 512

.cls2:
	mov qword [r14], 0
	add r14, 8
	loop .cls2 

.b2:
	; 检查该线性地址所对应的页表项是否存在
	call lin_to_lin_of_pte 

	ret 

; ------------------------------------------------------------
; setup_paging_for_laddr
; 功能: 为指定的线性地址安装分页
; 输入: r13=线性地址
; ------------------------------------------------------------
%ifdef __MP__
_spaging_locker dq 0
%endif

setup_paging_for_laddr:
	push rcx 
	push rax 
	push r14 
	pushfq

	cli 

%ifdef __MP__
	SET_SPIN_LOCK r14, qword [rel _spaging_locker]
%endif 

	call find_pte_for_laddr
	test qword [r14], 1
	jnz .exit

	; 创建并安装该地址对应的页表项, 即最终分配的页
	call allocate_a_4k_page
	or rax, 0x07										; 设置属性
	mov [r14], rax 

.exit:
%ifdef __MP__
	mov qword [rel _spaging_locker], 0
%endif
	popfq 

	pop r14 
	pop rax 
	pop rcx 

	ret 
; ------------------------------------------------------------
; mapping_laddr_to_page
; 功能: 建立线性地址到物理页的映射, 即, 为指定的线性地址安装指定的物理页
; 输入: r13=线性地址, rax=页的物理地址（含属性）
; ------------------------------------------------------------
%ifdef __MP__
_mapping_locker dq 0
%endif

mapping_laddr_to_page:
	push rcx 
	push r14 
	pushfq

	cli 

%ifdef __MP__
	SET_SPIN_LOCK r14, qword [rel _mapping_locker]
%endif

	push rax 
	call find_pte_for_laddr								; 得到页表项的线性地址
	pop rax 
	mov [r14], rax 										; 在页表项中写入页的物理地址

%ifdef __MP__
	mov qword [rel _mapping_locker], 0
%endif

	popfq
	pop r14 
	pop rcx 

	ret 
	
; ------------------------------------------------------------
; core_memory_allocate
; 功能: 在虚拟地址空间的高端（内核）分配内存
; 输入: rcx=请求分配的字节数
; 输出: r13=本次分配的起始线性地址, r14=下次分配的起始线性地址
; ------------------------------------------------------------
_core_next_linear dq CORE_ALLOC_START

%ifdef __MP__
_core_alloc_locker dq 0
%endif

core_memory_allocate:
	pushfq 
	cli 
%ifdef __MP__
	SET_SPIN_LOCK r14, qword [rel _core_alloc_locker]
%endif
	mov r13, [rel _core_next_linear]					; 起始地址
	lea r14, [r13 + rcx]								; 下次分配的起始地址

	test r14, 0x07 										; 进行 8 字节对齐处理
	jz .algn
	add r14, 0x08
	shr r14, 3
	shl r14, 3											; 最低的 3 个比特变 0

.algn:
	mov qword [rel _core_next_linear], r14 				; 写回, 保留, 下一次用

%ifdef __MP__
	mov qword [rel _core_alloc_locker], 0
%endif

	popfq

	push r13 
	push r14 

	; 以下为请求的内存分配页。R13 为本次分配的线性地址；R14 为下次分配的线性地址
	shr r13, 12
	shl r13, 12											; 清除页内偏移
	shr r14, 12
	shl r14, 12
.next:
	call setup_paging_for_laddr							; 安装线性地址所在页
	add r13, 0x1000
	cmp r13, r14 
	jle .next 

	pop r14 
	pop r13 

	ret 

; ------------------------------------------------------------
; user_memory_allocate
; 功能: 在用户任务的私有空间（低端）分配内存
; 输入: r11=任务控制块 PCB 的线性地址, rcx=希望分配的字节数
; 输出: r13=本次分配的起始线性地址, r14=下次分配的起始线性地址
; ------------------------------------------------------------
user_memory_allocate:
	mov r13, [r11 + 24]								; 获得本次分配的起始线性地址
	lea r14, [r13 + rcx]							; 下次分配的起始线性地址

	test r14, 0x07									; 是否按 8 字节对齐
	jz .algn
	shr r14, 3 										; 8 字节向上取整
	shl r14, 3 
	add r14, 0x08 

.algn:
	mov [r11 + 24], r14 							; 写回 PCB 中

	push r13 
	push r14 

	; 以下为请求的内存分配页
	shr r13, 12										; 清除页内便宜
	shl r13, 12
	shr r14, 12
	shl r14, 12

.next:
	call setup_paging_for_laddr						; 为当前线性地址安装页
	add r13, 0x1000
	cmp r13, r14 
	jle .next

	pop r14
	pop r13 

	ret 

; ------------------------------------------------------------
; copy_current_pml4
; 功能: 创建新的 4 级头表，并复制当前 4 级头表的内容
; 输出: rax=新 4 级头表的物理地址及属性
; ------------------------------------------------------------
%ifdef __MP__
_copy_locker dq 0
%endif

copy_current_pml4:
	push rsi 
	push rdi 
	push r13 
	push rcx 
	pushfq

	cli 

%ifdef __MP__
	SET_SPIN_LOCK rcx, qword [rel _copy_locker]
%endif

	call allocate_a_4k_page						; 分配一个物理页
	or rax, 0x07 								; 添加属性
	mov r13, NEW_PML4_LINEAR					; 用指定的线性地址映射和访问刚分配的这个物理页
	call mapping_laddr_to_page

	; 目标表项在页部件的转换速查缓冲器 TLB 的缓存, 需要用 invlpg 执行刷新
	invlpg [r13]

	mov rsi, 0xffff_ffff_ffff_f000				; rsi -> 当前活动4级头表的线性地址(还是利用递归映射)
	mov rdi, r13 								; rdi -> 新 4 级头表的线性地址
	mov rcx, 512								; rcx -> 要复制的目录项数
	cld 										; 将 RFLAGS 中的方向标志位（DF）设置为 0, 即地址自动递增
	repe movsq

	mov [r13 + 0xff8], rax 						; 0xff8 = 512 * 8, 新 4 级头表的 511 号表项指向它自己, 方便递归映射 
	invlpg [r13 + 0xff8]

%ifdef __MP__
	mov qword [rel _copy_locker], 0
%endif

	popfq
	pop rcx 
	pop r13
	pop rdi 
	pop rsi 

	ret 

; ------------------------------------------------------------
; get_cmos_time
; 功能: 从 CMOS 中获取当前时间, 详情见书中 225 页
; 输入: rbx=缓冲区线性地址
; ------------------------------------------------------------
%ifdef __MP__
_cmos_locker dq 0
%endif

get_cmos_time:
	push rax 
	pushfq
	cli 

%ifdef __MP__
	SET_SPIN_LOCK rax, qword [rel _cmos_locker]
%endif

.w0:
	mov al, 0x8a 
	out 0x70, al 
	in al, 0x71 								; 读寄存器 A
	test al, 0x80 								; 测试第 7 位 UIP, 等待更新周期结束
	jnz .w0 

	mov al, 0x84 
	out 0x70, al 
	in al, 0x71 								; 读RTC当前时间(时)
	mov ah, al 									; BCD 编码, 用两个寄存器处理

	shr ah, 4									; 处理高四位						
	and ah, 0x0f 
	add ah, 0x30 								; 转换成 ASCII
	mov [rbx], ah 

	and al, 0x0f 								; 处理低四位
	add al, 0x30 
	mov [rbx + 1], al 

	mov byte [rbx + 2], ":"

	mov al, 0x82 
	out 0x70, al 
	in al, 0x71									; 读RTC当前时间(分)
	mov ah, al 

	shr ah, 4			
	and ah, 0x0f 
	add ah, 0x30 
	mov [rbx + 3], ah 

	and al, 0x0f 
	add al, 0x30 
	mov [rbx + 4], al 

	mov byte [rbx + 5], ":"

	mov al, 0x80 
	out 0x70, al 
	in al, 0x71									; 读RTC当前时间(秒)
	mov ah, al 

	shr ah, 4
	and ah, 0x0f 
	add ah, 0x30
	mov [rbx + 6], ah 

	and al, 0x0f 
	add al, 0x30 
	mov [rbx + 7], al 

	mov byte [rbx + 8], 0						; 终止字符

%ifdef __MP__
	mov qword [rel _cmos_locker], 0
%endif

	popfq
	pop rax 

	ret 

; ------------------------------------------------------------
; generate_process_id
; 功能: 生成唯一的进程标识
; 输出: rax=进程标识
; ------------------------------------------------------------
_process_id dq 0

generate_process_id:
	mov rax, 1
	lock xadd qword [rel _process_id], rax 		; lock 前缀确保这条指令是原子操作, xadd 是 "交换并相加" 指令, 会将源操作数和目的操作数相加，结果存入目的操作数，同时将目的操作数的原始值存入源操作数
	
	ret 

; ------------------------------------------------------------
; generate_thread_id
; 功能: 生成唯一的线程标识
; 输出: rax=线程标识
; ------------------------------------------------------------
_thread_id dq 0

generate_thread_id:
	mov rax, 1
	lock xadd qword [rel _thread_id], rax 		; lock 前缀确保这条指令是原子操作, xadd 是 "交换并相加" 指令, 会将源操作数和目的操作数相加，结果存入目的操作数，同时将目的操作数的原始值存入源操作数
	
	ret 

; ------------------------------------------------------------
; get_screen_row
; 功能: 返回下一个屏幕坐标行的行号
; 输出: dh=行号
; ------------------------------------------------------------
_screen_row db 8 								; 前边已经显示了 7 行, 所以从 8 开始

get_screen_row:
	mov dh, 1
	lock xadd byte [rel _screen_row], dh 

	ret 

; ------------------------------------------------------------
; get_cpu_number
; 功能: 返回当前处理器的编号
; 输出: rax=处理器编号
; ------------------------------------------------------------
get_cpu_number:
	pushfq
	cli 
	swapgs
	mov rax, [gs:16]							; 在专属数据区取
	swapgs
	popfq
	ret 

; ------------------------------------------------------------
; memory_allocate
; 功能: 用户空间的内存分配
; 输入: rdx=期望分配的字节数
; 输出: r13=所分配内存的起始线性地址
; ------------------------------------------------------------
memory_allocate:
	push rcx 
	push r11 
	push r14 

	pushfq
	cli 
	swapgs
	mov r11, [gs:8]								; PCB 线性地址
	swapgs
	popfq

	mov rcx, rdx 
	call user_memory_allocate

	pop r14 
	pop r11 
	pop rcx 

	ret 