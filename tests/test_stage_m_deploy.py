"""
============================================================
阶段 M —— 群组治理 + 运维：部署层 TDD 契约测试（M5 / M7，规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§11 阶段 M / §13.3 运维与部署层编写契约测试：

    M5（P1-20 systemd 服务单元 + Docker 化）：
      - deploy/chatroom.service   systemd 服务单元（开机自启 + 崩溃拉起）
      - deploy/Dockerfile         容器化构建
      - deploy/docker-compose.yml 容器编排（数据卷持久化）
    M7（P1-22 首次启动配置向导）：
      - scripts/setup_wizard.py   交互式引导（管理员初始化/端口/证书/数据目录）

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- M5 systemd 服务单元 -----
  deploy/chatroom.service 必须存在，且：
    [Unit]    含 Description
    [Service] ExecStart 指向 python server/server_main.py（项目根目录绝对
              路径或工作目录为项目根）；Restart=on-failure（崩溃自动拉起）
    [Install] WantedBy=multi-user.target（开机自启）
    管理员密钥经 EnvironmentFile/Environment 注入（不硬编码在单元内）

  ----- M5 Docker 化 -----
  deploy/Dockerfile 必须存在，且：
    FROM python:3.12（或更高 3.x）
    安装项目依赖（pip install）
    EXPOSE 8090（默认服务端口）
    CMD/ENTRYPOINT 启动 server/server_main.py
  deploy/docker-compose.yml 必须存在，且：
    services.chatroom 服务定义
    ports 映射 8090
    volumes 持久化数据目录（users.db 与 file_store 所在目录）

  ----- M7 首次启动配置向导 -----
  scripts/setup_wizard.py 必须存在，且：
    Python 源码可编译（compile）
    暴露 run_wizard() 可调用入口（交互式引导不在此处实际执行）
    模块内 DEFAULT_CONFIG 提供最小配置模板（含 server.port /
    database.path / security.admin_secret_env），该模板可被 config.py
    的加载逻辑接受（yaml.safe_load 解析成功、config.get 可读）

【运行】
  实现前：本文件全部红（部署文件不存在），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_m_deploy.py -v
"""

import os
import sys

import pytest
import yaml

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


# ============================================================
# M5 —— systemd 服务单元
# ============================================================

class TestSystemdUnit:

    @pytest.fixture
    def unit_path(self):
        return os.path.join(PROJECT_ROOT, "deploy", "chatroom.service")

    def test_service_file_exists(self, unit_path):
        """deploy/chatroom.service 存在。"""
        assert os.path.exists(unit_path), \
            f"缺少部署文件: {unit_path}（阶段 M5 应创建 deploy/chatroom.service）"

    def test_unit_has_required_sections(self, unit_path):
        """单元含 [Unit] / [Service] / [Install] 三段。"""
        content = _read(unit_path)
        for section in ("[Unit]", "[Service]", "[Install]"):
            assert section in content, f"systemd 单元缺少 {section} 段"

    def test_unit_has_description(self, unit_path):
        """[Unit] 含 Description。"""
        content = _read(unit_path)
        assert "Description=" in content

    def test_unit_exec_start_launches_server_main(self, unit_path):
        """ExecStart 启动 server/server_main.py（工作目录为项目根）。"""
        content = _read(unit_path)
        assert "ExecStart=" in content
        exec_line = next(
            l for l in content.splitlines() if l.strip().startswith("ExecStart="))
        assert "server/server_main.py" in exec_line, \
            f"ExecStart 应指向 server/server_main.py: {exec_line}"
        assert "WorkingDirectory=" in content, \
            "应指定 WorkingDirectory（服务端依赖相对路径的 SSL/数据库）"

    def test_unit_restart_on_failure(self, unit_path):
        """崩溃自动拉起：Restart=on-failure。"""
        content = _read(unit_path)
        assert "Restart=on-failure" in content

    def test_unit_enable_on_boot(self, unit_path):
        """开机自启：WantedBy=multi-user.target。"""
        content = _read(unit_path)
        assert "WantedBy=multi-user.target" in content

    def test_unit_admin_secret_not_hardcoded(self, unit_path):
        """管理员密钥不硬编码：经 EnvironmentFile/Environment 注入。"""
        content = _read(unit_path)
        assert ("EnvironmentFile=" in content or "Environment=" in content), \
            "管理员密钥应经 EnvironmentFile/Environment 注入"


# ============================================================
# M5 —— Docker 化
# ============================================================

class TestDocker:

    @pytest.fixture
    def dockerfile_path(self):
        return os.path.join(PROJECT_ROOT, "deploy", "Dockerfile")

    @pytest.fixture
    def compose_path(self):
        return os.path.join(PROJECT_ROOT, "deploy", "docker-compose.yml")

    def test_dockerfile_exists(self, dockerfile_path):
        """deploy/Dockerfile 存在。"""
        assert os.path.exists(dockerfile_path), \
            f"缺少部署文件: {dockerfile_path}（阶段 M5 应创建 deploy/Dockerfile）"

    def test_dockerfile_python_base(self, dockerfile_path):
        """基础镜像为 python:3.12（或更高 3.x）。"""
        content = _read(dockerfile_path)
        assert "FROM python:3" in content, f"应使用 python 3.x 基础镜像: {content}"

    def test_dockerfile_installs_dependencies(self, dockerfile_path):
        """安装项目依赖。"""
        content = _read(dockerfile_path)
        assert "pip install" in content or "pip3 install" in content

    def test_dockerfile_exposes_port(self, dockerfile_path):
        """EXPOSE 默认服务端口 8090。"""
        content = _read(dockerfile_path)
        assert "EXPOSE" in content and "8090" in content

    def test_dockerfile_starts_server_main(self, dockerfile_path):
        """容器启动命令指向 server/server_main.py。"""
        content = _read(dockerfile_path)
        assert "server/server_main.py" in content, \
            f"CMD/ENTRYPOINT 应启动 server/server_main.py: {content}"

    def test_compose_exists_and_valid_yaml(self, compose_path):
        """docker-compose.yml 存在且为合法 YAML。"""
        assert os.path.exists(compose_path), \
            f"缺少部署文件: {compose_path}（阶段 M5 应创建 deploy/docker-compose.yml）"
        with open(compose_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        assert isinstance(data, dict) and "services" in data

    def test_compose_defines_chatroom_service(self, compose_path):
        """compose 定义 chatroom 服务。"""
        with open(compose_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        assert "chatroom" in data["services"], \
            f"应定义 chatroom 服务: {list(data['services'])}"

    def test_compose_maps_port_8090(self, compose_path):
        """ports 映射 8090（宿主端口可自定义）。"""
        with open(compose_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        ports = data["services"]["chatroom"].get("ports", [])
        assert any("8090" in str(p) for p in ports), f"应映射 8090 端口: {ports}"

    def test_compose_persists_data_volume(self, compose_path):
        """volumes 持久化数据（users.db 与 file_store 所在目录）。"""
        with open(compose_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        service = data["services"]["chatroom"]
        volumes = service.get("volumes", [])
        assert volumes, "应挂载数据卷持久化（数据库 + 文件存储）"
        joined = " ".join(str(v) for v in volumes)
        assert "file_store" in joined or "data" in joined or "/app" in joined


# ============================================================
# M7 —— 首次启动配置向导
# ============================================================

class TestSetupWizard:

    @pytest.fixture
    def wizard_path(self):
        return os.path.join(PROJECT_ROOT, "scripts", "setup_wizard.py")

    def test_wizard_exists(self, wizard_path):
        """scripts/setup_wizard.py 存在。"""
        assert os.path.exists(wizard_path), \
            f"缺少向导脚本: {wizard_path}（阶段 M7 应创建 scripts/setup_wizard.py）"

    def test_wizard_source_compiles(self, wizard_path):
        """向导脚本 Python 源码可编译（无语法错误）。"""
        source = _read(wizard_path)
        compile(source, wizard_path, "exec")

    def test_wizard_exposes_run_wizard(self, wizard_path):
        """模块暴露 run_wizard() 可调用入口。"""
        import importlib.util
        spec = importlib.util.spec_from_file_location("setup_wizard", wizard_path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        assert callable(getattr(module, "run_wizard", None)), \
            "向导应暴露 run_wizard() 函数（交互式引导入口）"

    def test_wizard_default_config_loadable_by_config(self, wizard_path):
        """向导提供的默认配置模板可被 config.py 加载逻辑接受。"""
        import importlib.util
        spec = importlib.util.spec_from_file_location("setup_wizard", wizard_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        template = getattr(module, "DEFAULT_CONFIG", None)
        assert isinstance(template, dict), "向导应提供 DEFAULT_CONFIG 模板"
        assert "server" in template and "port" in template["server"]
        assert "database" in template and "path" in template["database"]
        assert "security" in template and "admin_secret_env" in template["security"]

        # 模板经 yaml 序列化后必须能被 config 单例的加载逻辑解析
        from config import Config
        import tempfile
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml", delete=False, encoding="utf-8")
        try:
            yaml.safe_dump(template, tmp)
            tmp.close()
            cfg = Config()
            cfg._data = None
            cfg._load(tmp.name)
            assert cfg.get("server.port") is not None
            assert cfg.get("database.path") is not None
            assert cfg.get("security.admin_secret_env") is not None
        finally:
            os.unlink(tmp.name)
