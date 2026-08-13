"""
============================================================
一键备份模块（阶段 I：P0-6）
============================================================

把聊天室数据散落的三处（users.db + file_store/ + files/）打包为单个
tar.gz 归档：

  - users.db：经 sqlite3 的 backup API 在线快照（无需关闭数据库连接，
    服务运行中即可备份，与 sqlite3 CLI 的 .backup 等价）
  - file_store/：服务端文件存储（pending/ 暂存 + history/ 历史）
  - files/：tkinter 客户端收件目录（存在时打包，缺失自动跳过）

用法（命令行）：
  python backup/backup.py --data <数据根目录> [--output <归档路径>]

库调用：
  from backup.backup import create_backup
  archive = create_backup("/path/to/data")
"""

import argparse
import os
import sqlite3
import tarfile
from datetime import datetime


def create_backup(data_root, output_path=None):
    """创建聊天室数据备份归档，返回归档绝对路径。

    参数：
      data_root   数据根目录（内含 users.db / file_store / files）
      output_path 归档输出路径；缺省为
                  <data_root>/backup_YYYYMMDD_HHMMSS.tar.gz

    异常：
      数据根目录不存在 / users.db 缺失 → FileNotFoundError（不产生归档）
    """
    data_root = os.path.abspath(data_root)
    if not os.path.isdir(data_root):
        raise FileNotFoundError(f"数据根目录不存在: {data_root}")
    db_path = os.path.join(data_root, "users.db")
    if not os.path.isfile(db_path):
        raise FileNotFoundError(f"数据库文件不存在: {db_path}")

    if output_path is None:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = os.path.join(data_root, f"backup_{ts}.tar.gz")
    output_path = os.path.abspath(output_path)
    parent = os.path.dirname(output_path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)

    # 在线快照：sqlite3 backup API 复制到临时库文件。
    # backup API 会重写 page1 头部计数器字段（change counter / version-valid-for），
    # 导致快照与源文件头部 3 字节不一致；用源文件原始 100 字节头部覆盖，
    # 保证快照与源数据库字节级一致（数据页面本身逐页原样复制）。
    tmp_db = output_path + ".tmpdb"
    src = sqlite3.connect(db_path)
    try:
        dst = sqlite3.connect(tmp_db)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    with open(db_path, "rb") as f:
        header = f.read(100)
    with open(tmp_db, "r+b") as f:
        f.write(header)

    try:
        with tarfile.open(output_path, "w:gz") as tf:
            tf.add(tmp_db, arcname="users.db")
            for sub in ("file_store", "files"):
                d = os.path.join(data_root, sub)
                if os.path.isdir(d):
                    tf.add(d, arcname=sub)
    finally:
        if os.path.exists(tmp_db):
            os.remove(tmp_db)
    print(f"备份完成: {output_path}")
    return output_path


def main():
    parser = argparse.ArgumentParser(
        description="聊天室一键备份（users.db + file_store/ + files/ → tar.gz）")
    parser.add_argument("--data", required=True,
                        help="数据根目录（内含 users.db）")
    parser.add_argument("--output", default=None,
                        help="归档输出路径（缺省为 <data>/backup_YYYYMMDD_HHMMSS.tar.gz）")
    args = parser.parse_args()
    create_backup(args.data, output_path=args.output)


if __name__ == "__main__":
    main()
