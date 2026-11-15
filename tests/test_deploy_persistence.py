import os

import pytest
import yaml

from config import Config
from config import config as global_config
from database import Database

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _load_compose():
    with open(os.path.join(PROJECT_ROOT, "deploy", "docker-compose.yml"), "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


class TestComposeBuildContext:
    def test_dockerfile_path_resolved_against_context(self):
        compose = _load_compose()
        build = compose["services"]["chatroom"]["build"]
        assert build["context"] == ".."
        assert build["dockerfile"] == "deploy/Dockerfile"
        assert os.path.exists(os.path.join(PROJECT_ROOT, build["dockerfile"]))

    def test_data_volume_and_env_present(self):
        compose = _load_compose()
        service = compose["services"]["chatroom"]
        assert "chatroom-data:/app/data" in service["volumes"]
        assert "CHATROOM_DATA_DIR=/app/data" in service["environment"]

    def test_ssl_mounted_readonly_from_repo_root(self):
        compose = _load_compose()
        volumes = compose["services"]["chatroom"]["volumes"]
        assert any(v.endswith("/app/SSL:ro") and v.startswith("../SSL") for v in volumes)


class TestDockerfileContract:
    def test_dockerfile_key_directives(self):
        content = _read(os.path.join(PROJECT_ROOT, "deploy", "Dockerfile"))
        assert "WORKDIR /app" in content
        assert "ENV CHATROOM_DATA_DIR=/app/data" in content
        assert "mkdir -p /app/data" in content
        assert "EXPOSE" in content and "8090" in content
        assert "server/server_main.py" in content


class TestConfigEnvOverride:
    def test_env_dir_redirects_database_path(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        monkeypatch.setenv("CHATROOM_DATA_DIR", str(tmp_path / "data"))
        cfg = Config()
        assert cfg.get("database.path") == os.path.join(str(tmp_path / "data"), "users.db")

    def test_delenv_reload_restores_default(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        monkeypatch.setenv("CHATROOM_DATA_DIR", str(tmp_path / "data"))
        cfg = Config()
        monkeypatch.delenv("CHATROOM_DATA_DIR")
        cfg.reload()
        assert cfg.get("database.path") == "users.db"

    def test_empty_env_value_ignored(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        monkeypatch.setenv("CHATROOM_DATA_DIR", "   ")
        cfg = Config()
        assert cfg.get("database.path") == "users.db"

    def test_reload_reapplies_override(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        cfg = Config()
        assert cfg.get("database.path") == "users.db"
        monkeypatch.setenv("CHATROOM_DATA_DIR", str(tmp_path / "other"))
        cfg.reload()
        assert cfg.get("database.path") == os.path.join(str(tmp_path / "other"), "users.db")


class TestDatabasePersistence:
    def test_database_lands_in_data_dir_with_env(self, tmp_path, monkeypatch):
        saved = global_config._data
        try:
            monkeypatch.chdir(tmp_path)
            data_dir = str(tmp_path / "data")
            monkeypatch.setenv("CHATROOM_DATA_DIR", data_dir)
            global_config.reload()
            db = Database()
            assert os.path.abspath(db.db_name) == os.path.abspath(os.path.join(data_dir, "users.db"))
            store = db._file_store_dir()
            pending = db._pending_dir()
            history = db._history_dir()
            assert store == os.path.join(data_dir, "file_store")
            assert pending == os.path.join(data_dir, "file_store", "pending")
            assert history == os.path.join(data_dir, "file_store", "history")
            assert os.path.isdir(store) and os.path.isdir(pending) and os.path.isdir(history)
        finally:
            global_config._data = saved

    def test_database_creates_missing_parent_dirs(self, tmp_path):
        nested = tmp_path / "a" / "b" / "c" / "users.db"
        Database(str(nested))
        assert os.path.exists(str(nested))

    def test_same_path_reopen_keeps_data(self, tmp_path):
        path = str(tmp_path / "users.db")
        db1 = Database(path)
        db1.add_user("persist_user", "hash_x", is_admin=False)
        db2 = Database(path)
        assert db2.get_user("persist_user") is not None


class TestDockerignore:
    @pytest.fixture
    def dockerignore_lines(self):
        content = _read(os.path.join(PROJECT_ROOT, ".dockerignore"))
        return [line.strip() for line in content.splitlines() if line.strip() and not line.startswith("#")]

    def test_key_exclusions_present(self, dockerignore_lines):
        required = [
            ".git", ".venv", "__pycache__", "users.db", "users.db-*",
            "file_store", "files", "SSL", "dist", ".pytest_cache",
            "chatroom_flutter", ".dart_tool", "build", ".flutter-plugins",
            ".flutter-plugins-dependencies", "promo-video", "docs", "screenshots",
        ]
        for entry in required:
            assert entry in dockerignore_lines, f".dockerignore 缺少 {entry}"

    def test_runtime_sources_not_excluded(self, dockerignore_lines):
        kept = [
            "requirements.txt", "server", "database.py", "config.py",
            "protocol.py", "validation.py", "backup", "scripts", "deploy",
            "client", "config.yaml",
        ]
        for entry in kept:
            assert entry not in dockerignore_lines, f".dockerignore 误排除了 {entry}"
