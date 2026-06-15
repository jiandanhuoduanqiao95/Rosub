"""
============================================================
配置管理模块
============================================================

从 config.yaml 加载配置，文件不存在时使用内置默认值。
支持点分路径访问。

用法:
    from config import config
    port = config.get("server.port")
    timeout = config.get("message.recall_timeout_minutes")
"""

import os
import yaml


class Config:
    """配置单例，从 config.yaml 加载，文件缺失时回退到内置默认值"""

    _DEFAULTS = {
        "server": {
            "host": "127.0.0.1",
            "port": 8090,
            "ssl_cert": "SSL/tsetcn.crt",
            "ssl_key": "SSL/tsetcn.pem",
        },
        "client": {
            "host": "127.0.0.1",
            "port": 8090,
            "ssl_cert": "SSL/tsetcn.crt",
            "server_hostname": "tset.cn",
        },
        "protocol": {
            "version": "1.0.0",
            "chunk_size": 4194304,
        },
        "message": {
            "recall_timeout_minutes": 2,
        },
        "database": {
            "path": "users.db",
        },
    }

    def __init__(self):
        self._data = None

    def _load(self, path="config.yaml"):
        if self._data is not None:
            return
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                self._data = yaml.safe_load(f)
        else:
            self._data = dict(self._DEFAULTS)

    def get(self, key_path, default=None):
        """
        按点分路径获取配置值。

        示例:
            config.get("server.port")        -> 8090
            config.get("protocol.version")   -> "1.0.0"
        """
        self._load()
        keys = key_path.split(".")
        value = self._data
        for k in keys:
            if isinstance(value, dict):
                value = value.get(k)
                if value is None:
                    return default
            else:
                return default
        return value if value is not None else default

    def reload(self, path="config.yaml"):
        """强制重新加载配置（用于热更新场景）"""
        self._data = None
        self._load(path)


# 全局单例
config = Config()
