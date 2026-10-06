# QUICKSTART —— 5 分钟本地跑通 Rosub

> 目标：在本机（Linux/WSL/macOS 均可，Windows 客户端用 PowerShell 等价命令）同时跑起服务端与桌面客户端，注册两个账号互发消息。

## 0. 前置

- Python ≥ 3.11、Flutter 3.x stable
- 首次构建客户端需访问 GitHub / pub.dev（国内环境见 README「构建要求」的镜像设置）

## 1. 服务端（约 1 分钟）

```bash
git clone <本仓库> rosub && cd rosub   # 已 clone 可跳过
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

.venv/bin/python SSL/gen_cert.py        # 生成自签证书 SSL/tsetcn.crt|.pem（首次必须，缺证书服务端无法启动）

.venv/bin/python server/server_main.py  # 启动，默认监听 127.0.0.1:8090
```

看到日志 `服务器启动，监听 127.0.0.1:8090` 即成功。数据落在当前目录的 `users.db` 与 `file_store/`。

> 想让局域网其他设备连接：编辑根目录 `config.yaml`（不存在则新建，参考 `config.py` 的默认值），把 `server.host` 改为 `0.0.0.0`。

## 2. 客户端（约 3 分钟，首次含构建）

另开一个终端：

```bash
cd chatroom_flutter
flutter pub get
flutter run -d linux        # Windows 用 -d windows；Android 真机见下方说明
```

应用启动后：注册两个账号（如 `alice` / `bob`），互加好友（会话列表 → 加好友图标 → 搜索对方用户名），开聊。

> Android 真机：`flutter build apk --release --dart-define=CHATROOM_SERVER_HOST=<电脑局域网IP>`，
> 把生成的 arm64 APK 侧载到手机，手机与电脑连同一 Wi-Fi 即可连上你电脑上的服务端。

## 3. 跑测试（可选，约 2 分钟）

```bash
./run_tests.sh --all                          # Python 侧全量
cd chatroom_flutter && flutter test           # Flutter 侧全量
```

## 常见问题

| 现象 | 处理 |
|---|---|
| 服务端启动报证书错误 | 跳过了第 1 步的 `SSL/gen_cert.py`——回去执行 |
| 客户端登录失败/连接超时 | 确认服务端已启动、端口一致（8090）、Android 真机场景已注入 `CHATROOM_SERVER_HOST` |
| 管理员功能不可用 | 启动服务端前 `export CHATROOM_ADMIN_SECRET='任意长随机串'`，注册时开启管理员模式并填入同一密钥 |
| 中文输入法（Linux） | 使用 fcitx 输入法环境；客户端自带 GTK IME 桥接，详见 README「架构速览」 |
