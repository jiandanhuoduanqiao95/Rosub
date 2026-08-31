"""SSL 证书一键续期脚本（阶段 O8，P2-8）

复用 SSL/gen_cert.py 的自签名证书生成流程（generate_cert，days 参数化），
为服务端重新签发证书并覆写 config server.ssl_cert / server.ssl_key 指向的
文件。支持两种用法：

  # 仅检查当前证书剩余有效期（不续期）
  python scripts/renew_cert.py --check

  # 续期（默认 3650 天；可用 --days 覆盖）
  python scripts/renew_cert.py --days 3650

证书过期 = 全员无法登录（不可见但致命）；服务端启动自检与管理面板
（server_status 的 cert 字段 / renew_cert 命令）提供同等能力，本脚本供
部署/手动场景直接在主机上执行。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from config import config
from SSL.gen_cert import generate_cert


def _cert_paths():
    """从配置读取证书/私钥路径（与 build_listen 加载点一致）。"""
    config._load()
    cert_path = config.get("server.ssl_cert", "SSL/tsetcn.crt")
    key_path = config.get("server.ssl_key", "SSL/tsetcn.pem")
    hostname = config.get("client.server_hostname", "tset.cn")
    return cert_path, key_path, hostname


def check(cert_path=None):
    """检查证书剩余有效期，打印结果。返回 check_cert_expiry 的 dict。"""
    from server.server_main import Server

    if cert_path is None:
        cert_path, _key, _host = _cert_paths()
    # Server() 仅用于复用 check_cert_expiry（不监听、不启动线程）
    server = Server.__new__(Server)
    info = Server.check_cert_expiry(server, cert_path=cert_path)
    if not info["exists"]:
        print(f"[证书检查] 缺失或无法读取: {info['cert_path']}")
    elif info["expired"]:
        print(f"[证书检查] 已过期: {info['cert_path']}（剩余 "
              f"{info['days_left']:.1f} 天），请立即续期")
    elif info["warn"]:
        print(f"[证书检查] 即将过期: {info['cert_path']}（剩余 "
              f"{info['days_left']:.1f} 天），建议续期")
    else:
        print(f"[证书检查] 正常: {info['cert_path']}（剩余 "
              f"{info['days_left']:.1f} 天）")
    return info


def renew(days=3650):
    """续期：重新自签名证书覆写配置路径，返回新的检查结果 dict。"""
    cert_path, key_path, hostname = _cert_paths()
    os.makedirs(os.path.dirname(os.path.abspath(cert_path)) or ".", exist_ok=True)
    # 备份旧证书（存在时）
    for path in (cert_path, key_path):
        if os.path.exists(path):
            os.replace(path, path + ".bak")
    generate_cert(cert_path, key_path, key_path, [hostname], days=days)
    print(f"[证书续期] 已生成新证书: {cert_path}（有效期 {days} 天）")
    return check(cert_path)


def main():
    parser = argparse.ArgumentParser(description="聊天室 SSL 证书续期工具")
    parser.add_argument("--check", action="store_true",
                        help="仅检查当前证书剩余有效期（不续期）")
    parser.add_argument("--days", type=int, default=3650,
                        help="续期有效期（天，默认 3650）")
    args = parser.parse_args()
    if args.check:
        check()
    else:
        renew(days=args.days)


if __name__ == "__main__":
    main()
