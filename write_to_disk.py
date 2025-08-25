import os
import subprocess

# 硬盘路径
DISK_PATH = "C:/Users/Luan/VirtualBox VMs/AsmKernel/AsmKernel.vhd"


# 扇区大小
SECTOR_SIZE = 512

# 输出二进制文件加路径
BIN_PATH = "E:/ning/code/pc/AsmKernel/bin"

# dd 工具的路径
DD_PATH = "C:/Users/Luan/dd-0.5/dd.exe"

def write_to_disk(bin_path, lba_sector):
    """
    将二进制文件写入硬盘文件的指定 LBA 扇区号位置。

    :param bin_path: 二进制文件路径
    :param lba_sector: 目标 LBA 扇区号
    """
    try:
        # 使用 dd 命令将二进制文件写入指定偏移量
        command = [
            DD_PATH,
            f"if={bin_path}",  # 输入文件
            f"of={DISK_PATH}",  # 输出文件
            f"bs={SECTOR_SIZE}",  # 块大小
            f"seek={lba_sector}",  # 目标扇区号
        ]

        subprocess.run(command, check=True)

        print(f"成功将 {bin_path} 写入 {DISK_PATH} 的 LBA 扇区号 {lba_sector}。")

    except FileNotFoundError as e:
        print(f"错误：文件未找到 - {e}")
    except subprocess.CalledProcessError as e:
        print(f"错误：命令执行失败 - {e}")
    except Exception as e:
        print(f"发生未知错误 - {e}")

# 主函数
def main():
    # 映射关系在 global_defs.asm 文件有
    write_dict = {
        "mbr": 0,
        "ldr": 1,
        "core": 9,
        "shell": 50,
        "userapp0": 100
    }

    # 调用写入函数
    for bin_name, lba_sector in write_dict.items():
        bin_path = os.path.join(BIN_PATH, bin_name + ".bin")
        write_to_disk(bin_path, lba_sector)

if __name__ == "__main__":
    main()