"""
============================================================
阶段 I —— 消息可靠性 + 数据地基：I3 一键备份/恢复脚本
（TDD 契约，待实现）
============================================================

【目标】
  测试阶段 I3 引入的 backup 包（P0-6，见《软件开发文档4.1.0.md》
  §13.2 P0-6 / §11 阶段 I）：

    数据散落三处，一键打包为单个 tar.gz：
      - users.db            （SQLite 数据库，经 sqlite3 .backup 在线备份）
      - file_store/         （服务端文件存储：pending/ + history/）
      - files/              （tkinter 客户端收件目录，存在时打包）

【契约】
  新增 backup 包（实现时按此命名与语义落地）：
    backup/backup.py:
      create_backup(data_root, output_path=None)
        - data_root：数据根目录（内含 users.db / file_store / files）
        - 使用 sqlite3 的 backup API 在线备份数据库（不要求关闭连接）
        - 输出 tar.gz：成员相对路径 users.db、file_store/**、files/**
        - output_path 缺省时生成
          <data_root>/backup_YYYYMMDD_HHMMSS.tar.gz（时间戳）
        - data_root 不存在或 users.db 缺失 → 抛异常（不产生半成品归档）
        - 返回归档绝对路径
    backup/restore.py:
      restore_backup(archive_path, target_root)
        - 解压全部成员到 target_root（自动创建目录）
        - 目标已有同名文件 → 覆盖（幂等恢复）
        - 归档损坏/非备份格式 → 抛异常
      list_backup_members(archive_path)
        - 返回归档内成员相对路径列表（用于校验/预览）

【运行】
  阶段 I 实现前：每个用例在 backup_api 夹具中抛 ImportError（24 项红，
  不中断整个测试套件）。实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_i_backup.py -v
"""

import os
import re
import sqlite3
import sys
import tarfile

import pytest
import bcrypt

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# TDD 红：backup 包尚未实现时，每个用例在夹具中抛 ImportError（24 项红）；
# 实现后自动转绿，无需改动测试。集合阶段不中断整个测试套件。
from database import Database


@pytest.fixture
def backup_api():
    from backup.backup import create_backup
    from backup.restore import restore_backup, list_backup_members
    return create_backup, restore_backup, list_backup_members


def _hash(pw):
    return bcrypt.hashpw(pw.encode(), bcrypt.gensalt())


def _build_data_root(tmp_path, with_files_dir=True):
    """构造典型数据根目录：users.db + file_store/{pending,history} + files/。

    返回 (root, 文件字节内容对照 dict)
    """
    root = tmp_path / "data"
    root.mkdir()
    db = Database(str(root / "users.db"))
    db.add_user("alice", _hash("password123"))
    db.add_user("bob", _hash("password456"))
    db.save_message_history("alice", "bob", "chat", b"hello backup",
                            message_id="m1")
    db.save_offline_message("alice", "bob", "chat", b"offline",
                            message_id="m2")

    pending = root / "file_store" / "pending"
    history = root / "file_store" / "history"
    pending.mkdir(parents=True)
    history.mkdir(parents=True)
    file_pending = pending / "f1.bin"
    file_history = history / "f2.bin"
    file_pending.write_bytes(b"PENDING-DATA-123")
    file_history.write_bytes(b"HISTORY-DATA-456")

    contents = {
        "users.db": (root / "users.db").read_bytes(),
        "file_store/pending/f1.bin": file_pending.read_bytes(),
        "file_store/history/f2.bin": file_history.read_bytes(),
    }
    if with_files_dir:
        fdir = root / "files"
        fdir.mkdir()
        (fdir / "recv.txt").write_bytes(b"RECEIVED-DATA")
        contents["files/recv.txt"] = b"RECEIVED-DATA"
    return str(root), contents


# ============================================================
# I3-1 —— create_backup 归档生成
# ============================================================

class TestCreateBackup:

    def test_creates_tar_gz_archive(self, tmp_path, backup_api):
        """生成的归档为 tar.gz 且非空。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        assert out == str(tmp_path / "bk.tar.gz")
        assert os.path.isfile(out)
        assert os.path.getsize(out) > 0
        assert tarfile.is_tarfile(out)

    def test_archive_contains_database_and_file_dirs(self, tmp_path, backup_api):
        """归档成员 = users.db + file_store/** + files/**（相对路径）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        members = list_backup_members(out)
        assert "users.db" in members
        assert "file_store/pending/f1.bin" in members
        assert "file_store/history/f2.bin" in members
        assert "files/recv.txt" in members

    def test_archive_excludes_unrelated_files(self, tmp_path, backup_api):
        """归档只含 db + file_store + files，不打包无关文件/目录。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        with open(os.path.join(root, "secret.log"), "w") as f:
            f.write("should not be backed up")
        os.makedirs(os.path.join(root, "__pycache__"), exist_ok=True)
        with open(os.path.join(root, "__pycache__", "x.pyc"), "w") as f:
            f.write("pyc")
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        for m in list_backup_members(out):
            top = m.split("/")[0]
            assert top in ("users.db", "file_store", "files"), \
                f"归档包含无关成员: {m}"

    def test_archive_database_is_valid_sqlite(self, tmp_path, backup_api):
        """归档内 users.db 是有效 SQLite（.backup 在线快照），数据可查。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        with tarfile.open(out, "r:gz") as tf:
            with tf.extractfile("users.db") as f:
                blob = f.read()
        assert blob[:16] == b"SQLite format 3\x00"
        tmp_db = str(tmp_path / "check.db")
        with open(tmp_db, "wb") as f:
            f.write(blob)
        conn = sqlite3.connect(tmp_db)
        try:
            cur = conn.cursor()
            cur.execute("SELECT username FROM users ORDER BY username")
            assert [r[0] for r in cur.fetchall()] == ["alice", "bob"]
            cur.execute("SELECT content FROM message_history WHERE message_id='m1'")
            assert cur.fetchone()[0] == b"hello backup"
        finally:
            conn.close()

    def test_backup_online_safe_while_db_held(self, tmp_path, backup_api):
        """数据库被另一连接持有写事务时备份仍成功（sqlite .backup 在线特性）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        holder = sqlite3.connect(os.path.join(root, "users.db"))
        try:
            holder.execute("BEGIN IMMEDIATE")
            holder.execute(
                "INSERT INTO users (username, password_hash, is_admin) "
                "VALUES ('writer', ?, 0)", (_hash("pw"),)
            )
            out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        finally:
            holder.rollback()
            holder.close()
        assert os.path.isfile(out)
        members = list_backup_members(out)
        assert "users.db" in members

    def test_default_filename_has_timestamp(self, tmp_path, backup_api):
        """缺省 output_path 时生成 backup_YYYYMMDD_HHMMSS.tar.gz。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root)
        assert out == os.path.join(root, os.path.basename(out))
        assert re.fullmatch(
            r"backup_\d{8}_\d{6}\.tar\.gz", os.path.basename(out)
        ), os.path.basename(out)

    def test_custom_output_path_respected(self, tmp_path, backup_api):
        """显式 output_path 生效（含子目录自动创建）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out_path = str(tmp_path / "nested" / "dir" / "my.tar.gz")
        out = create_backup(root, output_path=out_path)
        assert out == out_path
        assert os.path.isfile(out_path)

    def test_backup_missing_db_raises(self, tmp_path, backup_api):
        """数据根目录存在但 users.db 缺失 → 抛异常，不产生归档。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root = tmp_path / "empty"
        root.mkdir()
        with pytest.raises(Exception):
            create_backup(str(root), output_path=str(tmp_path / "x.tar.gz"))
        assert not os.path.exists(str(tmp_path / "x.tar.gz"))

    def test_backup_nonexistent_root_raises(self, tmp_path, backup_api):
        """数据根目录不存在 → 抛异常。"""
        create_backup, restore_backup, list_backup_members = backup_api
        with pytest.raises(Exception):
            create_backup(str(tmp_path / "ghost"),
                          output_path=str(tmp_path / "x.tar.gz"))

    def test_backup_empty_file_dirs_ok(self, tmp_path, backup_api):
        """无 file_store/files 目录（仅 db）也能备份。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root = tmp_path / "onlydb"
        root.mkdir()
        Database(str(root / "users.db")).add_user("alice", _hash("pw"))
        out = create_backup(str(root), output_path=str(tmp_path / "bk.tar.gz"))
        members = list_backup_members(out)
        assert members == ["users.db"], members

    def test_repeated_backups_independent(self, tmp_path, backup_api):
        """连续两次备份互不干扰（各自完整）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        a = create_backup(root, output_path=str(tmp_path / "a.tar.gz"))
        b = create_backup(root, output_path=str(tmp_path / "b.tar.gz"))
        assert list_backup_members(a) == list_backup_members(b)


# ============================================================
# I3-2 —— restore_backup 恢复
# ============================================================

class TestRestoreBackup:

    def test_restore_recreates_tree(self, tmp_path, backup_api):
        """恢复后目录树与备份一致（db + 文件目录 + 子目录）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "restored")
        restore_backup(out, target)
        assert os.path.isfile(os.path.join(target, "users.db"))
        assert os.path.isfile(os.path.join(target, "file_store", "pending", "f1.bin"))
        assert os.path.isfile(os.path.join(target, "file_store", "history", "f2.bin"))
        assert os.path.isfile(os.path.join(target, "files", "recv.txt"))

    def test_restore_file_bytes_identical(self, tmp_path, backup_api):
        """恢复后的文件内容与备份时逐字节一致。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, contents = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "restored")
        restore_backup(out, target)
        for rel, blob in contents.items():
            with open(os.path.join(target, rel), "rb") as f:
                assert f.read() == blob, f"{rel} 内容不一致"

    def test_restored_database_usable(self, tmp_path, backup_api):
        """恢复后的 users.db 可被 Database 打开，数据完整可查。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "restored")
        restore_backup(out, target)
        db = Database(os.path.join(target, "users.db"))
        assert db.get_user("alice") is not None
        assert db.get_user("bob") is not None
        rows = db.get_message_history("alice", with_user="bob")
        assert any(r[4] == "m1" for r in rows)
        msgs = db.get_offline_messages("bob")
        assert any(m[4] == "m2" for m in msgs)

    def test_restore_overwrites_existing_files(self, tmp_path, backup_api):
        """目标已有同名文件 → 覆盖为备份版本（幂等恢复）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "restored")
        restore_backup(out, target)
        # 篡改目标文件后再次恢复 → 回到备份版本
        with open(os.path.join(target, "file_store", "pending", "f1.bin"), "wb") as f:
            f.write(b"TAMPERED")
        restore_backup(out, target)
        with open(os.path.join(target, "file_store", "pending", "f1.bin"), "rb") as f:
            assert f.read() == b"PENDING-DATA-123"

    def test_restore_creates_missing_parent_dirs(self, tmp_path, backup_api):
        """目标根目录不存在（含多层父目录）→ 自动创建。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "a" / "b" / "restored")
        restore_backup(out, target)
        assert os.path.isfile(os.path.join(target, "users.db"))

    def test_restore_backup_roundtrip(self, tmp_path, backup_api):
        """往返验证：改数据 → 备份 → 再改 → 恢复 → 回到备份时状态。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        # 备份后再写入新用户（模拟备份后继续使用）
        db = Database(os.path.join(root, "users.db"))
        db.add_user("carol", _hash("pw"))
        assert db.get_user("carol") is not None
        # 恢复
        target = str(tmp_path / "restored")
        restore_backup(out, target)
        restored = Database(os.path.join(target, "users.db"))
        assert restored.get_user("carol") is None, "恢复后不应有备份后的新用户"
        assert restored.get_user("alice") is not None

    def test_restore_archive_without_files_dir(self, tmp_path, backup_api):
        """仅 db 的归档恢复成功（无 files/ 成员不报错）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root = tmp_path / "onlydb"
        root.mkdir()
        Database(str(root / "users.db")).add_user("alice", _hash("pw"))
        out = create_backup(str(root), output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "restored")
        restore_backup(out, target)
        db = Database(os.path.join(target, "users.db"))
        assert db.get_user("alice") is not None

    def test_restore_corrupt_archive_raises(self, tmp_path, backup_api):
        """损坏/非备份格式的归档 → 抛异常。"""
        create_backup, restore_backup, list_backup_members = backup_api
        bad = tmp_path / "corrupt.tar.gz"
        bad.write_bytes(b"this is not a gzip archive at all" * 100)
        with pytest.raises(Exception):
            restore_backup(str(bad), str(tmp_path / "restored"))
        assert not os.path.exists(str(tmp_path / "restored"))

    def test_restore_plain_text_file_raises(self, tmp_path, backup_api):
        """普通文本文件（非 tar.gz）→ 抛异常。"""
        create_backup, restore_backup, list_backup_members = backup_api
        bad = tmp_path / "plain.txt"
        bad.write_text("hello")
        with pytest.raises(Exception):
            restore_backup(str(bad), str(tmp_path / "restored"))

    def test_restore_empty_tar_ok(self, tmp_path, backup_api):
        """空 tar.gz（无成员）→ 恢复成功且不报错（幂等）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        empty = tmp_path / "empty.tar.gz"
        with tarfile.open(str(empty), "w:gz") as tf:
            tf.close()
        target = str(tmp_path / "restored")
        restore_backup(str(empty), target)
        assert os.path.isdir(target)


# ============================================================
# I3-3 —— 与既有数据布局的兼容性
# ============================================================

class TestBackupCompatibility:

    def test_whole_project_layout_backup_restore(self, tmp_path, backup_api):
        """模拟真实项目布局：db 在根、file_store 同级，打包/恢复闭环。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "clone")
        restore_backup(out, target)
        assert os.path.isfile(os.path.join(target, "users.db"))
        assert os.path.isfile(os.path.join(target, "file_store", "history", "f2.bin"))

    def test_list_backup_members_relative_paths(self, tmp_path, backup_api):
        """成员全部为相对路径（不包含绝对路径前缀，防解压逃逸）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        for m in list_backup_members(out):
            assert not os.path.isabs(m), f"存在绝对路径成员: {m}"
            assert ".." not in m.split("/"), f"存在越界成员: {m}"

    def test_database_file_larger_than_zero_preserved(self, tmp_path, backup_api):
        """备份/恢复保持数据库文件大小一致（字节级）。"""
        create_backup, restore_backup, list_backup_members = backup_api
        root, _ = _build_data_root(tmp_path)
        out = create_backup(root, output_path=str(tmp_path / "bk.tar.gz"))
        target = str(tmp_path / "restored")
        restore_backup(out, target)
        orig = os.path.getsize(os.path.join(root, "users.db"))
        restored = os.path.getsize(os.path.join(target, "users.db"))
        assert restored == orig
