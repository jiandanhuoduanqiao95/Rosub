"""
============================================================
一键恢复模块（阶段 I：P0-6）
============================================================

从 backup.backup.create_backup 生成的 tar.gz 归档恢复聊天室数据到
指定目录（自动创建目录树，同名文件覆盖，幂等）。

安全性：解压前校验全部成员为相对路径且不含 ".."（防路径穿越）。

用法（命令行）：
  python backup/restore.py --archive <归档> --target <目标目录>

库调用：
  from backup.restore import restore_backup, list_backup_members
  restore_backup("/path/backup_20260812_101530.tar.gz", "/path/target")
"""

import argparse
import os
import tarfile


def list_backup_members(archive_path):
    """列出归档内全部成员相对路径。"""
    with tarfile.open(archive_path, "r:gz") as tf:
        return tf.getnames()


def restore_backup(archive_path, target_root):
    """把归档解压恢复到 target_root（自动创建目录，同名覆盖）。

    参数：
      archive_path 备份归档路径（tar.gz）
      target_root  恢复目标根目录

    异常：
      归档损坏 / 非 tar.gz 格式 → tarfile 异常（BadGzipFile / ReadError）
      归档含绝对路径或 ".." 成员 → ValueError（安全拒绝）
    """
    target_root = os.path.abspath(target_root)
    with tarfile.open(archive_path, "r:gz") as tf:
        for member in tf.getmembers():
            name = member.name
            if os.path.isabs(name) or ".." in name.split("/"):
                raise ValueError(f"归档包含不安全的成员路径: {name}")
        # 校验通过后才创建目标目录：损坏归档不产生任何目标文件
        os.makedirs(target_root, exist_ok=True)
        tf.extractall(target_root)
    print(f"恢复完成: {target_root}")


def main():
    parser = argparse.ArgumentParser(
        description="聊天室数据恢复（从 backup.py 生成的 tar.gz 还原）")
    parser.add_argument("--archive", required=True, help="备份归档路径")
    parser.add_argument("--target", required=True, help="恢复目标根目录")
    args = parser.parse_args()
    restore_backup(args.archive, args.target)


if __name__ == "__main__":
    main()
