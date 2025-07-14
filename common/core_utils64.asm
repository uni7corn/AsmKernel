; 内核通用程序

; 在多处理器环境中使用时, 需要在内核程序中定义宏 __MP__

%include "../common/global_defs.asm"

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

put_string64