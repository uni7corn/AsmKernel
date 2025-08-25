# 定义变量
ASM = nasm
SRCDIR = ./src
BINDIR = ./bin
LSTDIR = ./lst

# 默认目标
all: mbr ldr core shell userapp userapp0 userapp1

# 编译规则
mbr:
	$(ASM) -f bin $(SRCDIR)/mbr.asm -o $(BINDIR)/mbr.bin -l $(LSTDIR)/mbr.lst

ldr:
	$(ASM) -f bin $(SRCDIR)/ldr.asm -o $(BINDIR)/ldr.bin -l $(LSTDIR)/ldr.lst

core:
	$(ASM) -f bin $(SRCDIR)/core.asm -o $(BINDIR)/core.bin -l $(LSTDIR)/core.lst

shell:
	$(ASM) -f bin $(SRCDIR)/shell.asm -o $(BINDIR)/shell.bin -l $(LSTDIR)/shell.lst

userapp:
	$(ASM) -f bin $(SRCDIR)/userapp.asm -o $(BINDIR)/userapp.bin -l $(LSTDIR)/userapp.lst

userapp0:
	$(ASM) -f bin $(SRCDIR)/userapp0.asm -o $(BINDIR)/userapp0.bin -l $(LSTDIR)/userapp0.lst

userapp1:
	$(ASM) -f bin $(SRCDIR)/userapp1.asm -o $(BINDIR)/userapp1.bin -l $(LSTDIR)/userapp1.lst