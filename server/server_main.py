import socket
import ssl
import os
import sys
import time
import json
import logging
import collections
import threading

# 确保项目根目录在 Python 路径中（支持直接运行或作为模块导入）
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from database import Database
from server.server_call_handler import CallHandler
from server.server_client_handler import ClientHandler
from server.server_group_handler import GroupHandler
from config import config
from protocol import send_message

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

class Server:
    def __init__(self, host=None, port=None):
        self.host = host or config.get("server.host", "127.0.0.1")
        self.port = port or config.get("server.port", 8090)
        self.client_map = {}
        self.db = Database()
        self.client_map_lock = threading.Lock()
        self.client_handler = ClientHandler(self)
        # 群组处理器（Server 级引用，供定时消息投递等非会话路径复用；
        # 与 MessageHandler 内的实例同为无状态薄封装）
        self.group_handler = GroupHandler(self)
        # 通话信令处理器（阶段 R1：邀请/应答/挂断中继 + 占线状态，纯内存）
        self.call_handler = CallHandler(self)
        # 最近日志环形缓冲（阶段 M4：P1-19 服务端状态面板 recent_logs）
        self.recent_logs = collections.deque(maxlen=200)
        self._attach_recent_log_handler()
        # 正在被大文件直传转发（recv_and_forward 写入）的 socket 集合：
        # 转发期间禁止向这些连接写入任何其他数据（心跳 pong/kick/推送都会污染 SSL 流）
        self.active_forward_socks = set()
        # 大文件直传的**发送方**连接（recv_and_forward 读取期间）：
        # 心跳守护跳过该集合，避免长文件传输被误判为超时断开
        self.direct_transfer_sources = set()
        # 大文件传输专用通道（阶段 G4b 修复-问题2）：登录时带 transfer=1 的
        # 连接注册到此处，不进入 client_map、不踢主会话。
        # 文件数据在主连接之外收发，聊天消息在主连接上畅通无阻——
        # 发送方传输期间发的文字消息不再被发送队列/接收方抑制阻塞。
        self.transfer_sockets = {}
        # 会话最后活动时间戳（sock -> float）：心跳守护（阶段 L1 补充）依据。
        # 客户端每 30s 发送 ping，正常会话活动时间戳持续刷新；
        # 断网/进程异常等"无 FIN 断开"场景下连接半开，守护线程据此强制下线，
        # 避免幽灵会话导致对方一直显示在线。
        self.session_activity = {}
        # 在途发送引用计数（sock -> int）与待关闭集合：长发送（文件推送/
        # 直传转发）期间 socket 的 fd 不得被关闭，否则 fd 复用竞态会把
        # SSL 字节写进数据库文件（P-07 缺陷修复，见 guarded_send 说明）。
        self.sock_refs = {}
        self.sock_pending_close = set()
        # 已完成 SSL 握手但尚未注册进 client_map / transfer_sockets 的
        # 连接（登录/注册流程中）：guarded_send 活性校验对其放行，
        # 保证"密码错误"等认证前错误响应能送达；finally 中移除。
        self.pending_socks = set()
        # per-socket 写互斥锁（sock -> Lock）：SSL 对象非线程安全，任何
        # 并发的两次 sendall 会交错 TLS 记录（对端 BAD_LENGTH/EOF、双向
        # 流错位）。guarded_send（小消息，单次原子写）与文件长写
        # （send_file_message / 续传推送，逐块写）经此锁对同一 socket
        # 串行化——长写期间到来的推送在锁上排队，不丢失不交错。
        # （阶段 P 缺陷修复：离线 22MB 文件补发裸 sendall 与其他会话
        # 线程的 presence/聊天推送并发写同一 SSL socket → 登录初始数据
        # 阶段流错位 → 客户端断线重连死循环。）
        self.sock_write_locks = {}

    def _attach_recent_log_handler(self):
        """把最近日志接入环形缓冲（阶段 M4：状态面板 recent_logs）。"""
        class _BufferHandler(logging.Handler):
            def __init__(self, buf):
                super().__init__()
                self.buf = buf

            def emit(self, record):
                try:
                    self.buf.append(self.format(record))
                except Exception:
                    pass

        handler = _BufferHandler(self.recent_logs)
        handler.setFormatter(
            logging.Formatter('%(asctime)s [%(levelname)s] %(message)s'))
        logging.getLogger().addHandler(handler)

    def group_list_json(self, username):
        """用户群组列表 JSON（含群主/头像/历史可见性，阶段 M1/M3 推送扩展；
        阶段 O1/O2 追加 announcement / pinned_message_id / pinned_preview）。

        向后兼容：在既有 {"id", "group_name"} 基础上新增字段（旧客户端忽略）；
        新群组字段经 get_group_notices 平行访问器获取，
        get_user_groups_detailed 保持 6 元组不变（阶段 M 红线）。
        """
        groups = self.db.get_user_groups_detailed(username)
        notices = self.db.get_group_notices(username)
        return json.dumps([
            {"id": g[0], "group_name": g[1],
             "created_by": g[2], "avatar": g[3] or "",
             "history_visible": g[4], "history_limit": g[5],
             "announcement": notices.get(g[0], {}).get("announcement", ""),
             "pinned_message_id": notices.get(g[0], {}).get("pinned_message_id", ""),
             "pinned_preview": notices.get(g[0], {}).get("pinned_preview", ""),
             # 阶段 O 修订（2026-08-31 用户反馈：多置顶并存）：全量置顶列表
             "pinned_messages": self.db.get_group_pinned_messages(g[0])}
            for g in groups
        ])

    # ============================================================
    # 阶段 M4/M6（P1-19 状态面板 / P1-21 存储治理）
    # ============================================================

    def check_disk_usage(self, disk_free=None, disk_total=None):
        """磁盘剩余检查：剩余比例低于 storage.disk_warning_percent（默认 10）
        时 warn=True。参数可注入（测试/脚本复用，缺省取数据库所在文件系统）。"""
        if disk_free is None or disk_total is None:
            try:
                st = os.statvfs(os.path.dirname(os.path.abspath(self.db.db_name)))
                disk_free = st.f_bavail * st.f_frsize
                disk_total = st.f_blocks * st.f_frsize
            except Exception:
                disk_free = disk_free if disk_free is not None else 0
                disk_total = disk_total if disk_total is not None else 1
        threshold = config.get("storage.disk_warning_percent", 10)
        warn = disk_total > 0 and (disk_free / disk_total) * 100 < threshold
        return {"disk_free": disk_free, "disk_total": disk_total,
                "warn": bool(warn)}

    # ============================================================
    # 阶段 O8（P2-8）：证书过期检测 + 一键续期
    # ============================================================

    CERT_WARN_DAYS = 30  # 剩余天数低于该值触发预警（状态面板/日志提示）

    def check_cert_expiry(self, cert_path=None, now=None):
        """证书过期自检（O8）：解析 X.509 证书的 not_after。

        cert_path 缺省取 config server.ssl_cert（与 build_listen 加载点一致）；
        now 缺省取当前时间（epoch 秒）。返回：
          {"cert_path", "exists", "not_after"(epoch 秒|None),
           "days_left"(float|None), "expired", "warn"}
        文件缺失/解析失败 → exists=False, expired=True, days_left=None；
        warn：存在且未过期但 days_left <= CERT_WARN_DAYS。
        """
        if cert_path is None:
            cert_path = config.get("server.ssl_cert", "SSL/tsetcn.crt")
        if now is None:
            now = time.time()
        info = {"cert_path": cert_path, "exists": False, "not_after": None,
                "days_left": None, "expired": True, "warn": False}
        if not os.path.exists(cert_path):
            return info
        try:
            from cryptography import x509
            from cryptography.hazmat.primitives import serialization
            with open(cert_path, "rb") as f:
                cert = x509.load_pem_x509_certificate(f.read())
            not_after = cert.not_valid_after_utc.timestamp()
        except Exception as e:
            logging.warning(f"证书解析失败: {cert_path}, 错误={e}")
            return info
        days_left = (not_after - now) / 86400.0
        info["exists"] = True
        info["not_after"] = not_after
        info["days_left"] = days_left
        info["expired"] = days_left <= 0
        info["warn"] = (not info["expired"]
                        and days_left <= self.CERT_WARN_DAYS)
        return info

    def renew_cert(self, days=3650):
        """一键续期（O8）：重新自签名证书覆写 config 指向的证书/私钥路径。

        复用 SSL/gen_cert.py:generate_cert（days 参数化，默认 3650 向后兼容）。
        返回 check_cert_expiry 的新检查结果。运行中的旧连接不受影响，
        新 TLS 握手使用新证书。
        """
        import ssl as _ssl
        from SSL.gen_cert import generate_cert

        cert_path = config.get("server.ssl_cert", "SSL/tsetcn.crt")
        key_path = config.get("server.ssl_key", "SSL/tsetcn.pem")
        hostname = config.get("client.server_hostname", "tset.cn")
        os.makedirs(os.path.dirname(os.path.abspath(cert_path)) or ".",
                    exist_ok=True)
        generate_cert(cert_path, key_path, key_path, [hostname], days=days)
        # 已加载证书链的运行中上下文重载（新握手即用新证书；旧会话不受影响）
        context = getattr(self, "ssl_context", None)
        if context is not None:
            try:
                context.load_cert_chain(cert_path, key_path)
            except Exception as e:
                logging.warning(f"运行中 SSL 上下文重载失败（重启后生效）: {e}")
        logging.info(f"证书已续期: {cert_path}（有效期 {days} 天）")
        return self.check_cert_expiry(cert_path=cert_path)

    def _load_ssl_context(self):
        """构建并加载 SSL 上下文（build_listen 复用；保留引用供续期重载）。"""
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cert_path = config.get("server.ssl_cert", "SSL/tsetcn.crt")
        key_path = config.get("server.ssl_key", "SSL/tsetcn.pem")
        context.load_cert_chain(cert_path, key_path)
        self.ssl_context = context
        return context

    def run_storage_cleanup(self, days_file=7, days_delivered=30):
        """存储治理（P1-21）：过期文件请求清理 + 过期已读消息清理。

        返回 {"expired_file_requests", "expired_delivered_messages"}。
        message_history 为永久表，不参与清理（9.3 契约）。
        """
        expired_files = self.db.cleanup_expired_file_requests(days_file)
        expired_delivered = self.db.cleanup_expired_delivered_messages(days_delivered)
        logging.info(f"存储治理完成: 过期文件请求={expired_files}, "
                     f"过期已读消息={expired_delivered}")
        return {"expired_file_requests": expired_files,
                "expired_delivered_messages": expired_delivered}

    def get_server_status(self):
        """服务端状态面板数据（P1-19）：在线/存储/磁盘/日志聚合。"""
        with self.client_map_lock:
            online_sessions = len(self.client_map)
            online_users = len({u for (u, _d) in self.client_map})
        stats = self.db.get_storage_stats()
        return {
            "online_users": online_users,
            "online_sessions": online_sessions,
            "total_users": len(self.db.get_all_users()),
            "total_messages": stats["message_count"],
            "pending_file_requests": stats["pending_file_requests"],
            "storage": {
                "file_store_bytes": stats["file_store_bytes"],
                "file_count": stats["file_count"],
                "db_bytes": stats["db_bytes"],
            },
            "disk": self.check_disk_usage(),
            # 阶段 O8：证书过期自检结果（管理面板提示；旧客户端忽略新字段）
            "cert": self.check_cert_expiry(),
            "recent_logs": list(self.recent_logs)[-20:],
        }

    def _is_live_sock(self, sock):
        """该 socket 是否仍是活跃会话（发送前校验，避免写入已关闭的 fd）。

        P-07 缺陷修复：主会话在 client_map，传输通道在 transfer_sockets，
        认证握手中的连接在 pending_socks。已下线/被踢出的 socket 不再
        活跃 → guarded_send 跳过，杜绝"发送到已关闭 fd"（fd 复用竞态
        会把 TLS 字节写进数据库文件）。
        """
        return (sock in self.pending_socks
                or any(v is sock for v in self.client_map.values())
                or any(v is sock for v in self.transfer_sockets.values()))

    def _sock_write_lock(self, sock):
        """取（或创建）socket 的写互斥锁。锁字典经 client_map_lock 维护。"""
        with self.client_map_lock:
            lock = self.sock_write_locks.get(sock)
            if lock is None:
                lock = threading.Lock()
                self.sock_write_locks[sock] = lock
            return lock

    def with_sock_write(self, sock, write_fn):
        """在 per-socket 写锁内执行 [write_fn]（任意发送序列）。

        前置引用 socket（P-07：发送期间 fd 不被释放/复用），锁内不获取
        client_map_lock（等待写锁的线程不得持主锁，防死锁）。返回
        (acquired, result)：socket 已下线时 acquired=False。
        write_fn 抛出的异常向上传播（调用方按既有错误路径处理）。
        """
        if not self.acquire_send_sock(sock):
            return False, None
        try:
            with self._sock_write_lock(sock):
                return True, write_fn()
        finally:
            self.release_send_sock(sock)

    def guarded_send(self, sock, msg_type, content, extra_headers=None, chunk_size=None):
        """向客户端发送消息；若该连接正在接收大文件直传转发，则抑制写入。

        大文件直传时服务器把接收方 socket 当作纯文件通道，任何其他数据
        （ping/pong、kick 通知、聊天推送等）都会插入文件字节流导致 SSL 记录
        错乱（BAD_LENGTH）与文件损坏。

        P-07 缺陷修复（fd 复用竞态）：活性校验 + 引用计数——发送期间
        close_sock 延迟关闭，杜绝 sendall 落在被 sqlite 复用的 fd 上。

        阶段 P 缺陷修复（并发写交错）：发送经 per-socket 写锁串行——
        与文件长写（load_offline_data 补发/文件推送/续传，见 with_sock_write
        调用点）互斥，杜绝两个线程并发 sendall 同一 SSL socket 造成的
        TLS 记录交错（对端流错位 → 断线重连死循环）。长写期间本调用
        在写锁上排队等待，消息不丢失（活性失效则跳过）。
        """
        def _write():
            if sock in self.active_forward_socks:
                logging.info(f"抑制发送到转发中的连接: 类型={msg_type}")
                return
            if chunk_size is not None:
                send_message(sock, msg_type, content, extra_headers=extra_headers, chunk_size=chunk_size)
            else:
                send_message(sock, msg_type, content, extra_headers=extra_headers)

        acquired, _ = self.with_sock_write(sock, _write)
        if not acquired:
            logging.info(f"跳过发送到已下线连接: 类型={msg_type}")

    def acquire_send_sock(self, sock):
        """长发送（文件推送/直传转发）前引用 socket。

        返回 True 表示 socket 仍活跃且已被引用：引用期间任何关闭操作
        （close_sock）会延迟到 release_send_sock 之后真正关闭 fd，
        保证长发送不落在被复用为数据库文件的 fd 上（P-07 fd 复用竞态）。
        """
        with self.client_map_lock:
            if not self._is_live_sock(sock):
                return False
            self.sock_refs[sock] = self.sock_refs.get(sock, 0) + 1
            return True

    def release_send_sock(self, sock):
        """长发送结束后释放引用；若期间被标记待关闭则立即真正关闭。"""
        with self.client_map_lock:
            refs = self.sock_refs.get(sock, 0) - 1
            if refs > 0:
                self.sock_refs[sock] = refs
                return
            self.sock_refs.pop(sock, None)
            if sock in self.sock_pending_close:
                self.sock_pending_close.discard(sock)
                self.sock_write_locks.pop(sock, None)
                try:
                    sock.close()
                except Exception:
                    pass

    def close_sock(self, sock):
        """关闭会话 socket（内部取锁）：存在在途发送时延迟到引用清零。

        与 guarded_send 的写锁内发送互斥：发送要么先于关闭完成（真实
        socket），要么被活性校验跳过——任何 sendall 都不会落到已关闭
        且被数据库文件复用的 fd 上（P-07 fd 复用竞态修复）。
        """
        with self.client_map_lock:
            if self.sock_refs.get(sock, 0) > 0:
                self.sock_pending_close.add(sock)
                return
            self.sock_write_locks.pop(sock, None)
            try:
                sock.close()
            except Exception:
                pass

    # ============================================================
    # 阶段 L（P0-7）：多会话并存 —— client_map 双键化 (username, device_id)
    # ============================================================

    def sessions_of(self, username):
        """返回某用户名所有在线会话的 socket 列表（按 (username, device_id) 聚合）。

        阶段 L1：同一账号可在多个设备同时在线，每个设备一个主会话。
        """
        with self.client_map_lock:
            return [sock for (u, _d), sock in self.client_map.items() if u == username]

    def has_any_session(self, username):
        """该用户名是否有任一在线会话（presence 按用户名聚合的依据）。"""
        with self.client_map_lock:
            return any(u == username for (u, _d) in self.client_map)

    def session_count(self, username):
        """该用户名当前在线会话数。"""
        with self.client_map_lock:
            return sum(1 for (u, _d) in self.client_map if u == username)

    def device_id_of(self, sock):
        """返回某主会话 socket 对应的设备 id（阶段 L 多端前置）。

        用于在文件接受/拒绝等操作中记录响应设备，供其他设备提示
        "该文件已在XXX被接受/拒绝"。socket 不在主会话映射时回退 default。
        """
        with self.client_map_lock:
            for (u, d), s in self.client_map.items():
                if s is sock:
                    return d
        return "default"

    def remove_session(self, username, device_id, sock):
        """精确移除 (username, device_id) 会话映射；仅当仍指向 sock 时移除。

        防止旧会话线程退出时误删同用户新会话（阶段 G1 不变式在多会话下的推广）。
        """
        with self.client_map_lock:
            if self.client_map.get((username, device_id)) is sock:
                self.client_map.pop((username, device_id), None)

    def discard_socket(self, sock):
        """按 socket 身份移除其所在会话（异常路径清理，不误伤同用户其他会话）。

        P-07 补漏：若移除的是某用户名最后一个在线会话，须广播 presence 离线——
        发送失败路径（broadcast_to_user / 群文件推送 / 文件响应推送 / 公告）会
        经此把会话静默移出 client_map，此前不广播离线导致对方一直显示在线，
        只有重新登录（快照重建）才转离线。
        """
        with self.client_map_lock:
            dead = [k for k, v in self.client_map.items() if v is sock]
            for k in dead:
                self.client_map.pop(k, None)
            self.session_activity.pop(sock, None)
        for (u, _d) in dead:
            try:
                if not self.has_any_session(u):
                    self.broadcast_presence(u, False)
            except Exception as e:
                logging.warning(f"discard_socket presence 下线广播失败: 用户={u}, 错误={e}")

    # ============================================================
    # 心跳超时守护（阶段 L1 补充，P-07 幽灵会话修复）
    # ============================================================
    # 客户端每 30s 发送 ping；正常会话 last_activity 持续刷新。
    # 断网 / 进程异常 / 网络故障等"无 FIN 断开"会使连接半开，服务端
    # 永远感知不到断开 → 对方一直显示在线（P-07）。守护线程定期扫描，
    # 对"无活动超过 timeout 且非大文件传输中"的会话强制 shutdown，
    # 其线程 finally 正常清理并广播 presence 离线。

    HEARTBEAT_TIMEOUT = 120          # 无活动秒数阈值（客户端 30s ping，余量 4 周期）
    WATCHDOG_INTERVAL = 30           # 守护扫描周期（秒）

    def touch_activity(self, sock):
        """刷新会话最后活动时间（收到任何消息时调用）。"""
        self.session_activity[sock] = time.time()

    def watchdog_scan(self, now=None, timeout=HEARTBEAT_TIMEOUT):
        """单次超时扫描：对超时且非传输中的会话强制下线，返回被下线 socket 列表。

        可独立调用（测试直接驱动）；start_connection_watchdog 周期性调用。
        大文件直传的接收方（active_forward_socks）与发送方
        （direct_transfer_sources）均跳过——传输期间 ping 被抑制，
        不能被误判为超时（阶段 G4b 修复过的坑）。

        P-07 缺陷修复：仅 shutdown（唤醒阻塞在 recv 的会话线程）不 close——
        close 会释放 fd 触发 fd 复用竞态（见 guarded_send）；会话线程的
        finally 负责在锁内精确移除映射并关闭 socket。
        """
        now = now if now is not None else time.time()
        with self.client_map_lock:
            socks = (list(self.client_map.values())
                     + list(self.transfer_sockets.values()))
        killed = []
        for sock in socks:
            if (sock in self.active_forward_socks
                    or sock in self.direct_transfer_sources):
                continue
            last = self.session_activity.get(sock, now)
            if now - last < timeout:
                continue
            killed.append(sock)
            logging.warning(
                f"心跳超时，强制下线会话: 无活动 {now - last:.0f}s（阈值 {timeout}s）")
            try:
                # shutdown 唤醒阻塞在 recv 的会话线程（close 不能打断阻塞读），
                # 其 finally 会清理 client_map / transfer_sockets 并广播 presence 离线
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        # 清理已死会话的活动记录
        with self.client_map_lock:
            live = (set(self.client_map.values())
                    | set(self.transfer_sockets.values()))
        stale = [s for s in self.session_activity if s not in live]
        for s in stale:
            self.session_activity.pop(s, None)
        return killed

    def start_connection_watchdog(self, interval=None, timeout=None):
        """启动心跳守护线程（build_listen 调用；可覆盖间隔/阈值便于测试）。"""
        interval = interval if interval is not None else self.WATCHDOG_INTERVAL
        timeout = timeout if timeout is not None else self.HEARTBEAT_TIMEOUT

        def _watch():
            while True:
                time.sleep(interval)
                try:
                    self.watchdog_scan(timeout=timeout)
                except Exception as e:
                    logging.error(f"心跳守护扫描异常: {e}")

        self.watchdog_thread = threading.Thread(target=_watch, daemon=True)
        self.watchdog_thread.start()
        logging.info(f"心跳守护已启动: 间隔={interval}s, 超时={timeout}s")

    # ============================================================
    # 阶段 O5（P2-5 定时消息）：预约发送定时器
    # ============================================================

    SCHEDULER_INTERVAL = 5.0  # 定时器扫描周期（秒）

    def scheduler_scan(self, now=None):
        """单次到期扫描（O5）：投递全部到期的 pending 定时消息。

        可独立调用（测试直接驱动，仿 watchdog_scan）；
        start_scheduler 周期性调用。返回已投递的 message_id 列表。
        投递复用既有完整路径：
          - 私聊 = chat 路径：offline 落库 + history 落库 + 会话级推送
            （在线送达标记 delivered，接收方不在线则仅落库）
          - 群聊 = group_chat 路径：history 一条 + 离线成员副本
            （message_id=f"{id}_{成员}", group_id）+ notify_group_members
            群推送（跳过发送者）
        """
        try:
            self.call_handler.expire_calls(now=now)
        except Exception as e:
            logging.error(f"通话邀请过期清理异常: {e}")
        due = self.db.get_due_scheduled_messages(now)
        delivered_ids = []
        for item in due:
            message_id = item["message_id"]
            try:
                content = item["content"]
                if item["group_id"]:
                    group_id = item["group_id"]
                    for member in self.db.get_group_members(group_id):
                        if member != item["sender"]:
                            self.db.save_offline_message(
                                item["sender"], member, "group_chat",
                                json.dumps({"text": content,
                                            "group_id": group_id}).encode("utf-8"),
                                message_id=f"{message_id}_{member}",
                                group_id=group_id)
                    self.db.save_message_history(
                        item["sender"], "", "group_chat", content.encode("utf-8"),
                        group_id=group_id, message_id=message_id)
                    self.group_handler.notify_group_members(
                        group_id, "group_chat", content,
                        from_user=item["sender"],
                        extra_headers={"message_id": message_id})
                    # 发送者回显（群消息发送者被 notify 跳过，且定时消息无
                    # 本地即时回显——到点推一份给发送者全部会话，聊天流可见）
                    self.broadcast_to_user(
                        item["sender"], "group_chat", content,
                        extra_headers={"from": item["sender"],
                                       "group_id": str(group_id),
                                       "message_id": message_id})
                else:
                    receiver = item["receiver"]
                    self.db.save_offline_message(
                        item["sender"], receiver, "chat",
                        content.encode("utf-8"), message_id=message_id)
                    self.db.save_message_history(
                        item["sender"], receiver, "chat",
                        content.encode("utf-8"), message_id=message_id)
                    delivered = self.broadcast_to_user(
                        receiver, "chat", content,
                        extra_headers={"from": item["sender"],
                                       "message_id": message_id})
                    if delivered:
                        self.db.update_message_status(message_id, "delivered")
                    # 发送者回显（header 带 to，客户端路由到与接收方的会话）
                    self.broadcast_to_user(
                        item["sender"], "chat", content,
                        extra_headers={"from": item["sender"],
                                       "to": receiver,
                                       "message_id": message_id})
                self.db.mark_scheduled_message_sent(item["id"])
                delivered_ids.append(message_id)
                logging.info(f"定时消息已投递: 消息ID={message_id}, "
                             f"发送者={item['sender']}")
            except Exception as e:
                # 单条投递异常隔离：不影响其余到期消息（阶段 I 惯例）
                logging.error(f"定时消息投递异常（跳过）: 消息ID={message_id}, 错误={e}")
        return delivered_ids

    def start_scheduler(self, interval=None):
        """启动定时消息投递线程（O5，build_listen 调用；间隔可覆盖便于测试）。"""
        interval = interval if interval is not None else self.SCHEDULER_INTERVAL

        def _schedule_watch():
            while True:
                time.sleep(interval)
                try:
                    self.scheduler_scan()
                except Exception as e:
                    logging.error(f"定时消息扫描异常: {e}")

        self.scheduler_thread = threading.Thread(target=_schedule_watch,
                                                 daemon=True)
        self.scheduler_thread.start()
        logging.info(f"定时消息调度器已启动: 间隔={interval}s")

    def broadcast_to_user(self, username, msg_type, content, extra_headers=None):
        """向某用户名所有在线会话推送消息（会话级推送，阶段 L1）。

        逐会话发送并异常隔离；任一发送失败即移除该会话映射（不误伤同用户
        其他会话）。返回成功送达的会话数（0 = 用户离线）。
        """
        if extra_headers is None:
            extra_headers = {}
        delivered = 0
        with self.client_map_lock:
            socks = [sock for (u, _d), sock in self.client_map.items() if u == username]
        for sock in socks:
            try:
                self.guarded_send(sock, msg_type, content, extra_headers=extra_headers)
                delivered += 1
            except Exception as e:
                logging.warning(f"会话级推送失败: 用户={username}, 类型={msg_type}, 错误={e}")
                self.discard_socket(sock)
        return delivered

    def broadcast_presence(self, username, online):
        """向其他在线用户广播在线状态（阶段 J：P0-3；阶段 L1 按用户名聚合）。

        presence 按用户名而非设备聚合：任一设备在线即在线；向某目标用户推送
        一次即可（其所有会话都会收到——broadcast_to_user）。
        黑名单双向隐藏：subject 与 viewer 任一方向存在拉黑关系 → 不广播。
        """
        online_flag = "1" if online else "0"
        with self.client_map_lock:
            other_usernames = sorted({u for (u, _d) in self.client_map if u != username})
        for u in other_usernames:
            try:
                if self.db.is_blocked(u, username) or self.db.is_blocked(username, u):
                    continue
                self.broadcast_to_user(u, "presence", "",
                                       extra_headers={"from": username, "online": online_flag})
            except Exception as e:
                logging.warning(f"presence 广播失败: {username} -> {u}, 错误={e}")

    def send_presence_snapshot(self, username, ssock):
        """向新登录者发送当前其他在线用户的 presence 快照（黑名单双向隐藏）。

        快照须在初始数据（好友/群组列表）之前到达，客户端 _receiveInitialData
        在收到好友/群组列表前会持续消费消息。
        """
        with self.client_map_lock:
            others = sorted({u for (u, _d) in self.client_map if u != username})
        for u in others:
            try:
                if self.db.is_blocked(username, u) or self.db.is_blocked(u, username):
                    continue
                self.guarded_send(ssock, "presence", "",
                                  extra_headers={"from": u, "online": "1"})
            except Exception as e:
                logging.warning(f"presence 快照发送失败: {u} -> {username}, 错误={e}")

    def build_listen(self):
        if not os.path.exists("files"):
            os.makedirs("files")
        # 启动时清理过期文件请求
        cleaned = self.db.cleanup_expired_file_requests()
        if cleaned > 0:
            logging.info(f"启动时清理了 {cleaned} 个过期文件请求")
        # 阶段 O8：证书过期自检（启动即提示，过期/临近过期记 warning）
        cert_info = self.check_cert_expiry()
        if not cert_info["exists"]:
            logging.warning(f"SSL 证书缺失或无法读取: {cert_info['cert_path']}"
                            "（管理员可通过 renew_cert 一键续期）")
        elif cert_info["expired"]:
            logging.warning("SSL 证书已过期，客户端将无法建立新连接"
                            "（管理员可通过 renew_cert 一键续期）")
        elif cert_info["warn"]:
            logging.warning(f"SSL 证书即将过期（剩余 "
                            f"{cert_info['days_left']:.0f} 天），建议续期")
        context = self._load_ssl_context()
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind((self.host, self.port))
        server_socket.listen(100)
        # 心跳守护：清理"无 FIN 断开"的幽灵会话（断网/进程异常），
        # 避免对方一直显示在线（阶段 L1，P-07 修复）
        self.start_connection_watchdog()
        # 阶段 O5：定时消息投递线程（scheduler_scan 可测试直驱）
        self.start_scheduler()
        logging.info(f"服务器启动，监听 {self.host}:{self.port}")
        while True:
            try:
                client_socket, client_address = server_socket.accept()
                client_thread = threading.Thread(
                    target=self.client_handler.handle_client,
                    args=(client_socket, client_address, context)
                )
                client_thread.daemon = True
                client_thread.start()
            except Exception as e:
                logging.error(f"接受客户端连接时出错: {e}")

if __name__ == "__main__":
    server = Server()
    server.build_listen()