"""
============================================================
首次启动配置向导（阶段 M7：P1-22）
============================================================

交互式引导完成服务端首次部署：
  1. 管理员账号初始化（用户名/密码）
  2. 服务端口
  3. SSL 证书路径（存在性检查 + 自签名生成指引）
  4. 数据目录（users.db 与 file_store 所在位置）

用法：
  python scripts/setup_wizard.py          # 交互式引导
  python scripts/setup_wizard.py --check  # 只检查现有配置并输出建议

向导以 config.yaml 默认模板（DEFAULT_CONFIG）为基准生成配置，
生成结果可被 config.py 的加载逻辑直接解析（与 config.yaml 同构）。
"""

import argparse
import getpass
import os
import sys

# 与 config.py 内置默认值同构的最小配置模板（供测试与生成共用）
DEFAULT_CONFIG = {
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
    "file": {
        "max_file_size": 5368709120,
        "large_file_threshold": 314572800,
    },
    "database": {
        "path": "users.db",
    },
    "storage": {
        "disk_warning_percent": 10,
        "file_expire_days": 7,
        "delivered_expire_days": 30,
    },
    "security": {
        "admin_secret": "",
        "admin_secret_env": "CHATROOM_ADMIN_SECRET",
    },
}


def _prompt(text, default=None, secret=False):
    suffix = f" [{default}]" if default is not None else ""
    if secret:
        value = getpass.getpass(f"{text}{suffix}: ")
    else:
        value = input(f"{text}{suffix}: ").strip()
    return value if value else (default or "")


def _write_yaml(data, path):
    import yaml
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
    print(f"✔ 配置已写入: {path}")


def run_wizard():
    """交互式首次启动引导（P1-22）：管理员初始化/端口/证书/数据目录。"""
    print("=" * 56)
    print("  聊天室服务端 —— 首次启动配置向导")
    print("=" * 56)

    config = dict(DEFAULT_CONFIG)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    # 1. 服务端口
    port = _prompt("监听端口", default=config["server"]["port"])
    try:
        port = int(port)
    except ValueError:
        print(f"✘ 端口无效: {port}，使用默认 8090")
        port = 8090
    config["server"]["port"] = port
    config["client"]["port"] = port

    # 2. SSL 证书（存在性检查，缺失时给出生成指引）
    cert = _prompt("SSL 证书路径（相对项目根）", default=config["server"]["ssl_cert"])
    key = _prompt("SSL 私钥路径（相对项目根）", default=config["server"]["ssl_key"])
    config["server"]["ssl_cert"] = cert
    config["server"]["ssl_key"] = key
    cert_abs = os.path.join(root, cert)
    if not os.path.exists(cert_abs):
        print("⚠  未找到证书文件，请先生成自签名证书：")
        print("    openssl req -x509 -newkey rsa:2048 -nodes \\")
        print(f"      -keyout {key} -out {cert} -days 365 -subj '/CN=tset.cn'")

    # 3. 数据目录（users.db 与 file_store 所在位置）
    db_path = _prompt("数据库文件路径", default=config["database"]["path"])
    config["database"]["path"] = db_path
    data_dir = os.path.dirname(os.path.join(root, db_path))
    os.makedirs(data_dir, exist_ok=True)
    print(f"✔ 数据目录已就绪: {data_dir}（users.db + file_store/）")

    # 4. 管理员密钥：不落盘，仅提示用环境变量注入
    print("\n管理员密钥请通过环境变量注入（永不写入配置文件）：")
    print("    export CHATROOM_ADMIN_SECRET='<你的管理员密钥>'")
    print("    python server/server_main.py")

    # 5. 写出配置
    out = os.path.join(root, "config.yaml")
    if os.path.exists(out):
        choice = _prompt(f"config.yaml 已存在，是否覆盖（y/N）", default="N")
        if choice.lower() != "y":
            out = os.path.join(root, "config.generated.yaml")
    _write_yaml(config, out)

    print("\n" + "=" * 56)
    print("  向导完成。下一步：")
    print(f"  1. export CHATROOM_ADMIN_SECRET='<你的管理员密钥>'")
    print(f"  2. python server/server_main.py 启动服务端")
    print("=" * 56)
    return out


def _check_existing():
    """只读检查现有配置并输出建议（--check 模式）。"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cfg_path = os.path.join(root, "config.yaml")
    if not os.path.exists(cfg_path):
        print("⚠  未找到 config.yaml，建议运行向导生成（不带 --check）")
        return 1
    import yaml
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    server = data.get("server", {})
    print(f"✔ 配置存在: {cfg_path}")
    print(f"   端口: {server.get('port', 8090)}")
    cert = os.path.join(root, server.get("ssl_cert", "SSL/tsetcn.crt"))
    print(f"   证书: {'✔ 存在' if os.path.exists(cert) else '✘ 缺失'} ({cert})")
    print(f"   数据库: {server.get('database', {}).get('path', 'users.db')}")
    secret = os.environ.get("CHATROOM_ADMIN_SECRET")
    print(f"   管理员密钥环境变量: {'✔ 已设置' if secret else '⚠ 未设置（CHATROOM_ADMIN_SECRET）'}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="聊天室服务端首次启动配置向导")
    parser.add_argument("--check", action="store_true",
                        help="只检查现有配置并输出建议")
    args = parser.parse_args()
    if args.check:
        sys.exit(_check_existing())
    run_wizard()


if __name__ == "__main__":
    main()
