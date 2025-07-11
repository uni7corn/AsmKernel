; 内核通用程序

%include "..\common\global_defs.wid"

         bits 64

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
%ifdef __MP__
_prn_str_locker dq 0                  	;打印锁
%endif

put_string64:       	;显示0终止的字符串并移动光标
                     	;输入：RBX=字符串的线性地址
         push rbx
         push rcx

         pushfq     	;-->A
         cli
%ifdef __MP__
         SET_SPIN_LOCK rcx, qword [rel _prn_str_locker]
%endif

  .getc:
         mov cl, [rbx]
         or cl, cl                	;检测串结束标志（0）
         jz .exit                 	;显示完毕，返回
         call put_char
         inc rbx
         jmp .getc

  .exit:
%ifdef __MP__
         mov qword [rel _prn_str_locker], 0	;释放锁
%endif
         popfq                               	;A

         pop rcx
         pop rbx

         ret                                	;段内返回

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
put_char:                                 	;在屏幕上的当前光标处显示一个字符并推
	;进光标。
                                           	;输入：CL=字符ASCII码
         push rax
         push rbx
         push rcx
         push rdx
         push rsi
         push rdi

         ;以下取当前光标位置
         mov dx, 0x3d4
         mov al, 0x0e
         out dx, al
         inc dx                        	;0x3d5
         in al, dx                     	;高字
         mov ah, al

         dec dx                        	;0x3d4
         mov al, 0x0f
         out dx, al
         inc dx                        	;0x3d5
         in al, dx                     	;低字
         mov bx, ax                    	;BX=代表光标位置的16位数
         and rbx, 0x000000000000ffff 	;准备使用64位寻址方式访问显存

         cmp cl, 0x0d                  	;回车符？
         jnz .put_0a
         mov ax, bx
         mov bl, 80
         div bl
         mul bl
         mov bx, ax
         jmp .set_cursor

  .put_0a:
         cmp cl, 0x0a                 	;换行符？
         jnz .put_other
         add bx, 80
         jmp .roll_screen

  .put_other:                              	;正常显示字符
         shl bx, 1
         mov rax, UPPER_TEXT_VIDEO       	;在global_defs.wid中定义
         mov [rax + rbx], cl

         ;以下将光标位置推进一个字符
         shr bx, 1
         inc bx

  .roll_screen:
         cmp bx, 2000                       	;光标超出屏幕？滚屏
         jl .set_cursor

         push bx

         cld
         mov rsi, UPPER_TEXT_VIDEO + 0xa0   	;小心！64位模式下movsq
         mov rdi, UPPER_TEXT_VIDEO          	;使用的是rsi/rdi/rcx
         mov rcx, 480
         rep movsq
         mov bx, 3840                        	;清除屏幕最底一行
         mov rcx, 80                         	;64位程序应该使用RCX
  .cls:
         mov rax, UPPER_TEXT_VIDEO
         mov word[rax + rbx], 0x0720
         add bx, 2
         loop .cls

         pop bx
         sub bx, 80

  .set_cursor:
         mov dx, 0x3d4
         mov al, 0x0e
         out dx, al
         inc dx                         	;0x3d5
         mov al, bh
         out dx, al
         dec dx       	;0x3d4
         mov al, 0x0f
         out dx, al
         inc dx       	;0x3d5
         mov al, bl
         out dx, al

         pop rdi
         pop rsi
         pop rdx
         pop rcx
         pop rbx
         pop rax

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
;在指定位置用指定颜色显示0终止的字符串，只适用于打印图形字符。由于各程序打印时的坐标位置
;不同，互不干扰，不需要加锁和互斥。
%ifdef __MP__
_prnxy_locker dq 0
%endif

put_cstringxy64:                         	;输入：RBX=字符串首地址
                                          	;DH=行，DL=列
                                          	;R9B=颜色属性
         push rax
         push rbx
         push rcx
         push rdx
         push r8

         ;指定坐标位置在显存内的偏移量
         mov al, dh
         mov ch, 160                   	;每一行80个字符，占用160个字节
         mul ch
         shl dl, 1                     	;每个字符（列）占用2个字节，要乘以2
         and dx, 0x00ff
         add ax, dx                    	;得到指定坐标位置在显存内的偏移量
         and rax, 0x000000000000ffff

         pushfq                        	;-->A
         cli
%ifdef __MP__
         SET_SPIN_LOCK r8, qword [rel _prnxy_locker]
%endif

         mov r8, UPPER_TEXT_VIDEO     	;显存的起始线性地址
  .nextc:
         mov dl, [rbx]                 	;取得将要显示的字符
         or dl, dl
         jz .exit
         mov byte [r8 + rax], dl
         mov byte [r8 + rax + 1], r9b     	;字符颜色
         inc rbx
         add rax, 2                    	;增加一个字符的位置（2个字节）
         jmp .nextc
  .exit:
         xor r8, r8
%ifdef __MP__
         mov qword [rel _prnxy_locker], 0 	;释放锁
%endif
         popfq                              	;A

         pop r8
         pop rdx
         pop rcx
         pop rbx
         pop rax

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
make_call_gate:                          	;创建64位的调用门
                                          	;输入：RAX=例程的线性地址
                                          	;输出：RDI:RSI=调用门
         mov rdi, rax
         shr rdi, 32                     	;得到门的高64位，在RDI中

         push rax                        	;构造数据结构，并预置线性地址的位15~0
         mov word [rsp + 2], CORE_CODE64_SEL	;预置段选择子部分
         mov [rsp + 4], eax                  	;预置线性地址的位31~16
         mov word [rsp + 4], 0x8c00         	;添加P=1，TYPE=64位调用门
         pop rsi

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
make_interrupt_gate:                      	;创建64位的中断门
                                            	;输入：RAX=例程的线性地址
                                            	;输出：RDI:RSI=中断门
         mov rdi, rax
         shr rdi, 32                       	;得到门的高64位，在RDI中

         push rax                          	;构造数据结构，并预置线性地址的位15~0
         mov word [rsp + 2], CORE_CODE64_SEL	;预置段选择子部分
         mov [rsp + 4], eax                  	;预置线性地址的位31~16
         mov word [rsp + 4], 0x8e00         	;添加P=1，TYPE=64位中断门
         pop rsi

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
make_trap_gate:                             	;创建64位的陷阱门
                                             	;输入：RAX=例程的线性地址
                                             	;输出：RDI:RSI=陷阱门
         mov rdi, rax
         shr rdi, 32                        	;得到门的高64位，在RDI中

         push rax                           	;构造数据结构，并预置线性地址的位15~0
         mov word [rsp + 2], CORE_CODE64_SEL	;预置段选择子部分
         mov [rsp + 4], eax                  	;预置线性地址的位31~16
         mov word [rsp + 4], 0x8f00         	;添加P=1，TYPE=64位陷阱门
         pop rsi

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
make_tss_descriptor:                    	;创建64位的TSS描述符
                                          	;输入：RAX=TSS的线性地址
                                          	;输出：RDI:RSI=TSS描述符
         push rax

         mov rdi, rax
         shr rdi, 32                    	;得到门的高64位，在RDI中

         push rax                       	;先将部分线性地址移到适当位置
         shl qword [rsp], 16           	;将线性地址的位23~00移到正确位置
         mov word [rsp], 104           	;段界限的标准长度
         mov al, [rsp + 5]
         mov [rsp + 7], al             	;将线性地址的位31~24移到正确位置
         mov byte [rsp + 5], 0x89     	;P=1，DPL=00，TYPE=1001（64位TSS）
         mov byte [rsp + 6], 0        	;G、0、0、AVL和limit
         pop rsi                       	;门的低64位

         pop rax

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
mount_idt_entry:                     	;在中断描述符表IDT中安装门描述符
                                       	;R8=中断向量
                                       	;RDI:RSI=门描述符
         push r8
         push r9

         shl r8, 4                         	;中断号乘以16，得到表内偏移
         mov r9, UPPER_IDT_LINEAR        	;中断描述符表的高端线性地址
         mov [r9 + r8], rsi
         mov [r9 + r8 + 8], rdi

         pop r9
         pop r8

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
init_8259:                              	;初始化8259中断控制器，包括重新设置向量号
         push rax

         mov al, 0x11
         out 0x20, al                    	;ICW1：边沿触发/级联方式
         mov al, 0x20
         out 0x21, al  	;ICW2:起始中断向量（避开前31个异常的向量）
         mov al, 0x04
         out 0x21, al  	;ICW3:从片级联到IR2
         mov al, 0x01
         out 0x21, al                  	;ICW4:非总线缓冲，全嵌套，正常EOI

         mov al, 0x11
         out 0xa0, al                  	;ICW1：边沿触发/级联方式
         mov al, 0x28
         out 0xa1, al                  	;ICW2:起始中断向量-->0x28
         mov al, 0x02
         out 0xa1, al                  	;ICW3:从片识别标志，级联到主片IR2
         mov al, 0x01
         out 0xa1, al                  	;ICW4:非总线缓冲，全嵌套，正常EOI

         pop rax
         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
%ifdef __MP__
_read_hdd_locker dq 0                 	;读硬盘锁
%endif

read_hard_disk_0:                     	;从硬盘读取一个逻辑扇区
                                        	;RAX=逻辑扇区号
                                        	;RBX=目标缓冲区线性地址
                                        	;返回：RBX=RBX+512
         push rax
         push rcx
         push rdx

         pushfq                     	;-->A
         cli
%ifdef __MP__
         SET_SPIN_LOCK rdx, qword [rel _read_hdd_locker]
%endif

         push rax

         mov dx, 0x1f2
         mov al, 1
         out dx, al                	;读取的扇区数

         inc dx                    	;0x1f3
         pop rax
         out dx, al               	;LBA地址7~0

         inc dx                   	;0x1f4
         mov cl, 8
         shr rax, cl
         out dx, al   	;LBA地址15~8

         inc dx       	;0x1f5
         shr rax, cl
         out dx, al  	;LBA地址23~16

         inc dx       	;0x1f6
         shr rax, cl
         or al, 0xe0  	;第一硬盘  LBA地址27~24
         out dx, al

         inc dx       	;0x1f7
         mov al, 0x20 	;读命令
         out dx, al

  .waits:
         in al, dx
         ;and al, 0x88
         ;cmp al, 0x08
         test al, 8
         jz .waits              	;不忙，且硬盘已准备好数据传输

         mov rcx, 256                 			;总共要读取的字数
         mov dx, 0x1f0
  .readw:
         in ax, dx
         mov [rbx], ax
         add rbx, 2
         loop .readw

%ifdef __MP__
         mov qword [rel _read_hdd_locker], 0			;释放锁
%endif
         popfq                              			;A

         pop rdx
         pop rcx
         pop rax

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  _page_bit_map times 2*1024/4/8 db 0xff          	;对应物理内存的前512个页面（2MB）
          times (PHY_MEMORY_SIZE-2)*1024/4/8 db 0 	;对应后续的页面
  _page_map_len  equ $ - _page_bit_map

allocate_a_4k_page:                       			;分配一个4KB的页
                                            			;输入：无
                                            			;输出：RAX=页的物理地址
         xor rax, rax
  .b1:
         lock bts [rel _page_bit_map], rax			;多处理器需要lock，单处理器不需要
         jnc .b2
         inc rax
         cmp rax, _page_map_len * 8      			;立即数符号扩展到64位进行比较
         jl .b1

         ;对我们这个简单的系统来说，通常不存在页面不够分配的情况。对于一个流行的系统来说，
         ;如果页面不够分配，需要在这里执行虚拟内存管理，即，回收已经注销的页面，或者执行页
         ;面的换入和换出。

  .b2:
         shl rax, 12                         			;乘以4096（0x1000）

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lin_to_lin_of_pml4e:     	;返回指定的线性地址所对应的4级头表项的线性地址
                                     	;输入：R13=线性地址
                                     	;输出：R14=对应的4级头表项的线性地址
         push r13

         mov r14, 0x0000_ff80_0000_0000 	;保留4级头表索引部分
         and r13, r14
         shr r13, 36                   	;原4级头表索引变成页内偏移

         mov r14, 0xffff_ffff_ffff_f000  	;访问4级头表所用的地址前缀
         add r14, r13

         pop r13

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lin_to_lin_of_pdpte:    	;返回指定的线性地址所对应的页目录指针项的线性地址
                                    	;输入：R13=线性地址
                                    	;输出：R14=对应的页目录指针项的线性地址
         push r13

         mov r14, 0x0000_ffff_c000_0000	;保留4级头表索引和页目录指针表索引部分
         and r13, r14
         shr r13, 27      	;原4级头表索引变成页表索引，原页目录指针表索引变页内偏移

         mov r14, 0xffff_ffff_ffe0_0000	;访问页目录指针表所用的地址前缀
         add r14, r13

         pop r13

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lin_to_lin_of_pdte:                	;返回指定的线性地址所对应的页目录项的线性地址
                                     	;输入：R13=线性地址
                                     	;输出：R14=对应的页目录项的线性地址
         push r13

         mov r14, 0x0000_ffff_ffe0_0000	;保留4级头表索引、页目录指针表索引和页目录表
	                                ;索引部分
         and r13, r14
         shr r13, 18       		;原4级头表索引变成页目录表索引，原页目录指针
		                        ;表索引变页表索引，原页目录表索引变页内偏移
         mov r14, 0xffff_ffff_c000_0000	;访问页目录表所用的地址前缀
         add r14, r13
         pop r13

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lin_to_lin_of_pte:               	;返回指定的线性地址所对应的页表项的线性地址
                                   	;输入：R13=线性地址
                                   	;输出：R14=对应的页表项的线性地址
         push r13

         mov r14, 0x0000_ffff_ffff_f000	;保留4级头表、页目录指针表、页目录表和页表的
	                                ;索引部分
         and r13, r14
         shr r13, 9         	        ;原4级头表索引变成页目录指针表索引，原页目录指针表索引变
                           	        ;页目录表索引，原页目录表索引变页表索引，原页表索引变页内偏移
         mov r14, 0xffff_ff80_0000_0000	;访问页表所用的地址前缀
         add r14, r13

         pop r13
         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
%ifdef __MP__
_spaging_locker dq 0
%endif

setup_paging_for_laddr:          	;为指定的线性地址安装分页系统（表项）
                                   	;输入：R13=线性地址
         push rcx
         push rax
         push r14

         pushfq                   	;-->A
         cli
%ifdef __MP__
         SET_SPIN_LOCK r14, qword [rel _spaging_locker]
%endif

         ;在当前活动的4级分页体系中，所有线性地址对应的4级头表始终是存在的。
         ;检查该线性地址所对应的4级头表项是否存在
         call lin_to_lin_of_pml4e    	;得到4级头表项的线性地址
         test qword [r14], 1         	;P位是否为“1”。表项是否存在？
         jnz .b0

         ;创建并安装该线性地址所对应的4级头表项（创建页目录指针表）
         call allocate_a_4k_page        	;分配一个页做为页目录指针表
         or rax, 0x07                    	;添加属性位 U/S=R/W=P=1
         mov [r14], rax                  	;在4级头表中登记4级头表项（页目录指针表地址）

         ;清空刚分配的页目录指针表
         call lin_to_lin_of_pdpte
         shr r14, 12
         shl r14, 12                   	;得到页目录指针表的线性地址
         mov rcx, 512
  .cls0:
         mov qword [r14], 0
         add r14, 8
         loop .cls0
;-------------------------------------------------
  .b0:
         ;检查该线性地址所对应的页目录指针项是否存在
         call lin_to_lin_of_pdpte      	;得到页目录指针项的线性地址
         test qword [r14], 1           	;P位是否为“1”。表项是否存在？
         jnz .b1                        	;页目录指针项是存在的，转.b1

         ;创建并安装该线性地址所对应的页目录指针项（分配页目录表）
         call allocate_a_4k_page      	;分配一个页做为页目录表
         or rax, 0x07                  	;添加属性位
         mov [r14], rax                	;在页目录指针表中登记页目录指针项（页目录表地址）

         ;清空刚分配的页目录表
         call lin_to_lin_of_pdte
         shr r14, 12
         shl r14, 12                      	;得到页目录表的线性地址
         mov rcx, 512
  .cls1:
         mov qword [r14], 0
         add r14, 8
         loop .cls1
;-------------------------------------------------
  .b1:
         ;检查该线性地址所对应的页目录项是否存在
         call lin_to_lin_of_pdte
         test qword [r14], 1               	;P位是否为“1”。表项是否存在？
         jnz .b2                            	;页目录项已存在，转.b2

         ;创建并安装该线性地址所对应的页目录项（分配页表）
         call allocate_a_4k_page          	;分配一个页做为页表
         or rax, 0x07                      	;添加属性位
         mov [r14], rax                    	;在页目录表中登记页目录项（页表地址）

         ;清空刚分配的页表
         call lin_to_lin_of_pte
         shr r14, 12
         shl r14, 12                       	;得到页表的线性地址
         mov rcx, 512
  .cls2:
         mov qword [r14], 0
         add r14, 8
         loop .cls2
;-------------------------------------------------
  .b2:
         ;检查该线性地址所对应的页表项是否存在
         call lin_to_lin_of_pte
         test qword [r14], 1              	;P位是否为“1”。表项是否存在？
         jnz .b3                           	;页表项已经存在，转.b3

         ;创建并安装该线性地址所对应的页表项（分配最终的页）
         call allocate_a_4k_page         	;分配一个页
         or rax, 0x07                     	;添加属性位
         mov [r14], rax                   	;在页表中登记页表项（页的地址）

  .b3:
%ifdef __MP__
         mov qword [rel _spaging_locker], 0
%endif
         popfq                      	;A

         pop r14
         pop rax
         pop rcx

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
%ifdef __MP__
_mapping_locker dq 0
%endif

mapping_laddr_to_page:           	;建立线性地址到物理页的映射
                                   	;即，为指定的线性地址安装指定的物理页
                                   	;输入：R13=线性地址
                                                   ;RAX=页的物理地址（含属性）
         push rcx
         push r14

         pushfq
         cli
%ifdef __MP__
         SET_SPIN_LOCK r14, qword [rel _mapping_locker]
%endif

         push rax

         ;在当前活动的4级分页体系中，所有线性地址对应的4级头表始终是存在的。
         ;检查该线性地址所对应的4级头表项是否存在
         call lin_to_lin_of_pml4e 	;得到4级头表项的线性地址
         test qword [r14], 1      	;P位是否为“1”。表项是否存在？
         jnz .b0

         ;创建并安装该线性地址所对应的4级头表项（分配页目录指针表）
         call allocate_a_4k_page   	;分配一个页做为页目录指针表
         or rax, 0x07               	;添加属性位 U/S=R/W=P=1
         mov [r14], rax             	;在4级头表中登记4级头表项（页目录指针表地址）

         ;清空刚分配的页目录指针表
         call lin_to_lin_of_pdpte
         shr r14, 12
         shl r14, 12           	;得到页目录指针表的线性地址
         mov rcx, 512
  .cls0:
         mov qword [r14], 0
         add r14, 8
         loop .cls0
;-------------------------------------------------
  .b0:
         ;检查该线性地址所对应的页目录指针项是否存在
         call lin_to_lin_of_pdpte  	;得到页目录指针项的线性地址
         test qword [r14], 1       	;P位是否为“1”。表项是否存在？
         jnz .b1                    	;页目录指针项是存在的，转.b1

         ;创建并安装该线性地址所对应的页目录指针项（分配页目录表）
         call allocate_a_4k_page  	;分配一个页做为页目录表
         or rax, 0x07              	;添加属性位
         mov [r14], rax            	;在页目录指针表中登记页目录指针项（页目录表地址）

         ;清空刚分配的页目录表
         call lin_to_lin_of_pdte
         shr r14, 12
         shl r14, 12                 	;得到页目录表的线性地址
         mov rcx, 512
  .cls1:
         mov qword [r14], 0
         add r14, 8
         loop .cls1
;-------------------------------------------------
  .b1:
         ;检查该线性地址所对应的页目录项是否存在
         call lin_to_lin_of_pdte
         test qword [r14], 1           	;P位是否为“1”。表项是否存在？
         jnz .b2                        ;页目录项已存在，转.b2

         ;创建并安装该线性地址所对应的页目录项（分配页表）
         call allocate_a_4k_page      	;分配一个页做为页表
         or rax, 0x07                  	;添加属性位
         mov [r14], rax                	;在页目录表中登记页目录项（页表地址）

         ;清空刚分配的页表
         call lin_to_lin_of_pte
         shr r14, 12
         shl r14, 12                   	;得到页表的线性地址
         mov rcx, 512
  .cls2:
         mov qword [r14], 0
         add r14, 8
         loop .cls2
;-------------------------------------------------
  .b2:
         call lin_to_lin_of_pte       	;得到页表项的线性地址
         pop rax
         mov [r14], rax                	;在页表中登记页表项（页的地址）

%ifdef __MP__
         mov qword [rel _mapping_locker], 0
%endif
         popfq

         pop r14
         pop rcx

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  _core_next_linear  dq CORE_ALLOC_START 	;下一次分配时可用的起始线性地址

%ifdef __MP__
  _core_alloc_locker dq 0
%endif

core_memory_allocate:                 	        ;在虚拟地址空间的高端（内核）分配内存
                                        	;输入：RCX=请求分配的字节数
                                        	;输出：R13=本次分配的起始线性地址
                                        	;      R14=下次分配的起始线性地址
         pushfq                        	        ;A-->
         cli
%ifdef __MP__
         SET_SPIN_LOCK r14, qword [rel _core_alloc_locker]
%endif

         mov r13, [rel _core_next_linear]  	;获得本次分配的起始线性地址
         lea r14, [r13 + rcx]               	;下次分配时的起始线性地址

         test r14, 0x07                     	;最低3位是000吗（是否按8字节对齐）？
         jz .algn
         add r14, 0x08                      	;注：立即数符号扩展到64位参与操作
         shr r14, 3
         shl r14, 3                       	;最低3个比特变成0，强制按8字节对齐。

  .algn:
         mov [rel _core_next_linear], r14 	;写回。

%ifdef __MP__
         mov qword [rel _core_alloc_locker], 0	;释放锁
%endif
         popfq                             	;A

         push r13
         push r14

         ;以下为请求的内存分配页。R13为本次分配的线性地址；R14为下次分配的线性地址
         shr r13, 12
         shl r13, 12                    	;清除掉页内偏移部分
         shr r14, 12
         shl r14, 12                    	;too
  .next:
         call setup_paging_for_laddr  	;安装当前线性地址所在的页
         add r13, 0x1000               	;+4096
         cmp r13, r14
         jle .next

         pop r14
         pop r13

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
user_memory_allocate:            	;在用户任务的私有空间（低端）分配内存
                                   	;输入：R11=任务控制块PCB的线性地址
                                   	;      RCX=希望分配的字节数
                                   	;输出：R13=本次分配的起始线性地址
                                   	;      R14=下次分配的起始线性地址
         ;获得本次内存分配的起始线性地址
         mov r13, [r11 + 24]     	;获得本次分配的起始线性地址
         lea r14, [r13 + rcx]    	;下次分配时的起始线性地址

         test r14, 0x07          	;能够被8整除吗（是否按8字节对齐）？
         jz .algn
         shr r14, 3
         shl r14, 3                     ;最低3个比特变成0，强制按8字节对齐。
         add r14, 0x08   	        ;注：立即数符号扩展到64位参与操作

  .algn:
         mov [r11 + 24], r14         	;写回PCB中。

         push r13
         push r14

         ;以下为请求的内存分配页。R13为本次分配的线性地址；R14为下次分配的线性地址
         shr r13, 12
         shl r13, 12                 	;清除掉页内偏移部分
         shr r14, 12
         shl r14, 12                 	;too
  .next:
         call setup_paging_for_laddr   	;安装当前线性地址所在的页
         add r13, 0x1000                ;+4096
         cmp r13, r14
         jle .next

         pop r14
         pop r13

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
%ifdef __MP__
_copy_locker dq 0
%endif

copy_current_pml4:                    	;创建新的4级头表，并复制当前4级头表的内容
                                        	;输入：无
                                        	;输出：RAX=新4级头表的物理地址及属性
         push rsi
         push rdi
         push r13
         push rcx

         pushfq                                   	;-->A
         cli
%ifdef __MP__
         SET_SPIN_LOCK rcx, qword [rel _copy_locker]
%endif

         call allocate_a_4k_page          	;分配一个物理页
         or rax, 0x07                      	;立即数符号扩展到64位参与操作
         mov r13, NEW_PML4_LINEAR         	;用指定的线性地址映射和访问这个页
         call mapping_laddr_to_page

         ;相关表项在修改前存在遗留，本次修改必须刷新。
         invlpg [r13]

         mov rsi, 0xffff_ffff_ffff_f000   	;RSI->当前活动4级头表的线性地址
         mov rdi, r13                       	;RDI->新4级头表的线性地址
         mov rcx, 512                       	;RCX=要复制的目录项数
         cld
         repe movsq

         mov [r13 + 0xff8], rax            	;新4级头表的511号表项指向它自己
         invlpg [r13 + 0xff8]

%ifdef __MP__
         mov qword [rel _copy_locker], 0
%endif
         popfq                    	;A

         pop rcx
         pop r13
         pop rdi
         pop rsi

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
%ifdef __MP__
_cmos_locker dq 0
%endif

get_cmos_time:                        	;从CMOS中获取当前时间
                                       	;输入：RBX=缓冲区线性地址
         push rax

         pushfq                       	;-->A
         cli
%ifdef __MP__
         SET_SPIN_LOCK rax, qword [rel _cmos_locker]
%endif

  .w0:
         mov al, 0x8a
         out 0x70, al
         in al, 0x71                 	;读寄存器A
         test al, 0x80               	;测试第7位UIP，等待更新周期结束。
         jnz .w0

         mov al, 0x84
         out 0x70, al
         in al, 0x71                 	;读RTC当前时间(时)
         mov ah, al

         shr ah, 4
         and ah, 0x0f
         add ah, 0x30
         mov [rbx], ah

         and al, 0x0f
         add al, 0x30
         mov [rbx + 1], al

         mov byte [rbx + 2], ':'

         mov al, 0x82
         out 0x70, al
         in al, 0x71             	;读RTC当前时间(分)
         mov ah, al

         shr ah, 4
         and ah, 0x0f
         add ah, 0x30
         mov [rbx + 3], ah

         and al, 0x0f
         add al, 0x30
         mov [rbx + 4], al

         mov byte [rbx + 5], ':'

         mov al, 0x80
         out 0x70, al
         in al, 0x71             	;读RTC当前时间(秒)
         mov ah, al              	;分拆成两个数字

         shr ah, 4                   	;逻辑右移4位
         and ah, 0x0f
         add ah, 0x30
         mov [rbx + 6], ah

         and al, 0x0f               	;仅保留低4位
         add al, 0x30               	;转换成ASCII
         mov [rbx + 7], al

         mov byte [rbx + 8], 0     	;空字符终止

%ifdef __MP__
         mov qword [rel _cmos_locker], 0
%endif
         popfq                	;A

         pop rax

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  _process_id        dq 0

generate_process_id:                  	;生成唯一的进程标识
                                        	;返回：RAX=进程标识
         mov rax, 1
         lock xadd qword [rel _process_id], rax

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  _thread_id dq 0

generate_thread_id:                 	;生成唯一的线程标识
                                      	;返回：RAX=线程标识
         mov rax, 1
         lock xadd qword [rel _thread_id], rax

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  _screen_row        db 8

get_screen_row:                     	;返回下一个屏幕坐标行的行号
                                     	;返回：DH=行号
         mov dh, 1
         lock xadd byte [rel _screen_row], dh

         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
get_cpu_number:                        	;返回当前处理器的编号
                                        	;返回：RAX=处理器编号
         pushfq
         cli
         swapgs
         mov rax, [gs:16]              	;从处理器专属数据区取回
         swapgs
         popfq
         ret

;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
memory_allocate:                       	;用户空间的内存分配
                                         	;进入：RDX=期望分配的字节数
                                       	;输出：R13=所分配内存的起始线性地址
         push rcx
         push r11
         push r14

         pushfq
         cli
         swapgs
         mov r11, [gs:8]                	;取得当前任务的PCB线性地址
         swapgs
         popfq

         mov rcx, rdx
         call user_memory_allocate

         pop r14
         pop r11
         pop rcx

         ret
;~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
