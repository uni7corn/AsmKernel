; 内核通用程序

; 在多处理器环境中使用时, 需要在内核程序中定义宏 __MP__

%include "./common/global_defs.asm"

	bits 64

; ------------------------------------------------------------
; put_cstringxy64
; 功能: 在指定位置用指定颜色显示 0 终止的字符串，只适用于打印图形字符。由于各程序打印时的坐标位置不同，互不干扰，不需要加锁和互斥。
; 输入: rbx=字符串首地址, dh=行, dl=列, r9b=颜色属性
; ------------------------------------------------------------
%ifdef __MP__ 
_prnxy_locker dp 0
%endif 

put_cstringxy64:
	push rax 
	push rbx 
	push rcx 
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
