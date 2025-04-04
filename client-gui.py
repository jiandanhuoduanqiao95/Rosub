import socket
import ssl
import os
import threading
from protocol import send_message, recv_message


class Client:
    def listen_for_messages(self, ssock):
        """后台线程：持续监听并打印来自服务器的消息和文件"""
        while True:
            header, data = recv_message(ssock)
            if header is None:  # 新增检查
                print("服务器未响应，连接可能已断开")
                return
            if header.get("type") == "error":
                print("错误:", data.decode("utf-8"))
                return
            if not header:
                break
            msg_type = header.get("type")
            if msg_type == "chat":
                if "history" in header:
                    print(f"[历史消息] 来自 {header['from']}: {data.decode('utf-8')}")
                else:
                    if "from" in header:
                        print(f"来自 {header['from']} 的消息: {data.decode('utf-8')}")
                    else:
                        print("服务器:", data.decode("utf-8"))
            elif msg_type == "file":
                filename = header.get("filename", "received_file")
                if "history" in header:
                    print(f"[历史文件] 来自 {header['from']}: {filename}")
                    # 保存文件逻辑
                    file_path = f"files/recv_{filename}"
                    with open(file_path, 'wb') as f:
                        f.write(data)  # data 是完整的文件内容
                    print(f"[历史文件] {filename} 已保存至 {file_path}")
                else:
                    #filename = header.get("filename", "received_file")
                    filesize = header.get("filesize", 0)
                    print(f"开始接收文件 {filename} ({filesize} bytes)...")
                    file_path = f"files/recv_{filename}"
                    # 直接使用 data 写入文件，无需循环 recv
                    with open(file_path, 'wb') as f:
                        f.write(data)  # data 是完整的文件内容
                    print(f"文件 {filename} 已接收，保存在 {file_path}")
            else:
                print("未知消息类型", header)
        print("连接断开")

    def send_message_and_file(self):
        # 生成SSL上下文
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations("SSL/tsetcn.crt")

        client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_socket.connect(('127.0.0.1', 8090))


        # 确保server_hostname与证书中的CN一致
        with context.wrap_socket(client_socket, server_hostname='tset.cn') as ssock:
            # # 注册：输入用户名并发送注册消息
            # username = input("用户名:").strip()
            # send_message(ssock, "register", username)
            # # 接收注册/欢迎消息
            # header, data = recv_message(ssock)
            # if header and header.get("type") == "chat":
            #     print("服务器:", data.decode("utf-8"))

            # 用户选择注册或登录
            action = input("请选择操作 (register/login): ").strip().lower()
            username = input("用户名:").strip()
            password = input("密码:").strip()

            if action == "register":
                send_message(ssock, "register", username, extra_headers={"password": password})
            elif action == "login":
                send_message(ssock, "login", username, extra_headers={"password": password})
            else:
                print("无效操作")
                return

            # 接收服务器响应
            header, data = recv_message(ssock)
            if header.get("type") == "error":
                print("错误:", data.decode("utf-8"))
                return
            print("服务器:", data.decode("utf-8"))

            # 启动后台线程，持续监听来自服务器的消息（包括转发的消息和文件）
            threading.Thread(target=self.listen_for_messages, args=(ssock,), daemon=True).start()

            # 主线程用于发送消息或文件
            while True:
                target = input("请选定消息接收者:").strip()
                mode = input("请选择操作(chat/file/quit): ").strip()
                if mode == "quit":
                    send_message(ssock, "chat", "quit")
                    break
                elif mode == "chat":
                    msg = input("请输入聊天内容: ")
                    send_message(ssock, "chat", msg, extra_headers={"to": target})
                elif mode == "file":
                    filepath = input("请输入待传输文件路径: ").strip()
                    #清理路径中的引号
                    filepath = filepath.strip('"')
                    if not os.path.isfile(filepath):
                        print("文件不存在")
                        continue
                    filename = os.path.basename(filepath)
                    filesize = os.path.getsize(filepath)
                    # # 发送文件传输请求头，附带目标用户信息
                    # send_message(ssock, "file", b"",
                    #              extra_headers={"filename": filename, "filesize": filesize, "to": target})
                    try:
                        with open(filepath, "rb") as f:
                            file_data=f.read()
                            #通过协议发送完整文件(文件头和内容)
                            send_message(ssock,'file',file_data,extra_headers={"filename":filename,"to":target})
                        print(f"文件 {filename} 已发送")
                    except Exception as e:
                        print(f"发送文件失败: {e}")
                else:
                    print("无效操作，请重新输入。")
            print("客户端关闭")


if __name__ == "__main__":
    client = Client()
    client.send_message_and_file()

