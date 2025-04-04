import socket
import ssl
import os
from protocol import send_message, recv_message
import threading
import logging
import bcrypt
from database import Database

# 配置日志记录
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')


class Server:
    def __init__(self, host="127.0.0.1", port=8090):
        self.host = host
        self.port = port
        # 使用字典保存注册用户：用户名 -> ssl_socket
        self.client_map = {}
        #新增数据库实例
        self.db=Database()
        #新增锁对象,在将用户添加到client_map时加锁，避免多线程冲突
        self.client_map_lock=threading.Lock()

    def handle_client(self, client_socket, client_address, context):
        logging.info(f"新客户端连接: {client_address}")

        try:
            with context.wrap_socket(client_socket, server_side=True) as ssock:
                # 第一步：接收注册消息（类型 "register"）
                header, data = recv_message(ssock)
                if not header or header.get("type") not in ("register","login"):
                    send_message(ssock, "chat", "错误，请先注册")
                    ssock.close()
                    return

                msg_type=header.get("type")
                username=data.decode("utf-8").strip()
                password=header.get("password")#从消息头获取密码
                #通过类型区分
                if msg_type=="register":
                    if self.db.user_exists(username):
                        send_message(ssock,"error","用户已存在")
                        ssock.close()
                        return
                    #生成密码哈希
                    password_hash=bcrypt.hashpw(password.encode('utf-8'),bcrypt.gensalt())

                    if self.db.add_user(username,password_hash):
                        send_message(ssock,"chat","注册成功")
                        #self.client_map[username]=ssock
                        # 上锁
                        with self.client_map_lock:  # 加锁
                            self.client_map[username] = ssock
                    else:
                        send_message(ssock,"error","注册失败")

                elif msg_type=="login":
                    user_data=self.db.get_user(username)
                    if not user_data:
                        send_message(ssock,"error","错误，用户不存在")
                        ssock.close()
                        return
                    stored_hash=user_data[0]
                    #检验密码
                    if bcrypt.checkpw(password.encode('utf-8'), stored_hash):
                        send_message(ssock, "chat", "登录成功")
                        #self.client_map[username] = ssock
                        # 上锁
                        with self.client_map_lock:
                            self.client_map[username] = ssock
                    else:
                        send_message(ssock, "error", "错误：密码错误")
                        ssock.close()
                        return

                while True:
                    # 用户登录/注册成功后，检查并发送离线消息
                    messages = self.db.get_offline_messages(username)
                    if messages:
                        for msg in messages:
                            sender, msg_type, content, filename = msg
                            if msg_type == "chat":
                                send_message(ssock, "chat", content.decode('utf-8'),
                                             extra_headers={"from": sender, "history": "true"})
                            elif msg_type == "file":
                                send_message(ssock, "file", content,
                                             extra_headers={"from": sender, "filename": filename, "history": "true"})

                    header, data = recv_message(ssock)
                    if not header or not data:  # 新增对 header 和 data 的检查
                        logging.info("客户端主动断开连接")
                        break
                    msg_type = header.get("type")

                    if msg_type == "chat":
                        target = header.get("to")
                        if not target:
                            send_message(ssock, "chat", "错误，未指定接收者")
                            continue

                        message = data.decode("utf-8")
                        logging.info(f"来自 {username} 发往 {target} 的聊天消息: {message}")
                        #if target in self.client_map:
                        with self.client_map_lock:  # 加锁
                            recipient_socket=self.client_map.get(target)
                        if recipient_socket:
                            #接收方在线则直接转发
                            # 转发消息给目标用户，同时附加发送者信息
                            send_message(recipient_socket, "chat", message, extra_headers={"from": username})
                            # send_message(ssock, "chat", f"消息已发送给 {target}")
                        else:
                            #接收方离线则保存到数据库
                            self.db.save_offline_message(username,target,"chat",message.encode('utf-8'))
                            send_message(ssock,"chat",f"用户{target}离线，消息已保存")

                        if message.lower() == "quit":
                            break

                    elif msg_type == "file":
                        target = header.get("to")
                        with self.client_map_lock:  # 加锁
                            recipient_socket = self.client_map.get(target)
                            target_online = recipient_socket is not None
                        if not target_online:
                            #接收方离线，保存文件信息到数据库
                            filename=header.get("filename","received_file")
                            self.db.save_offline_message(
                                username,target,"file",data,
                                filename=filename
                            )
                            send_message(ssock,"chat",f"用户{target}离线，文件已保存")
                            continue

                        filename = header.get("filename", "received_file")
                        file_data=data#data已经通过协议接收完整的文件内容

                        # 保存文件并发送
                        file_path = f"files/recv_{username}_to_{target}_{filename}"
                        try:
                            with open(file_path,'wb') as f:
                                f.write(file_data)

                            #发送文件头时包含实际文件大小
                            #filesize=len(file_data)
                            # 直接发送给接收方
                            send_message(recipient_socket,"file",file_data,extra_headers={"from":username,"filename":filename,"filesize":len(file_data)})

                            logging.info(f"文件{filename}已接收并转发")
                            #send_message(recipient_socket,"file",file_data,extra_headers={"from":username,"filename":filename})
                        except Exception as e:
                            logging.error(f"接收文件失败: {e}")
                            #continue
                        logging.info(f"文件 {filename} 已接收完毕，保存为 {file_path}")
                    else:
                        logging.warning(f"未知消息类型来自 {username}")
        except ssl.SSLError as e:
            logging.error(f"SSL 错误: {e}")
        except Exception as e:
            logging.error(f"处理客户端 {client_address} 时出错: {e}")
        finally:
            # 清理：删除断开连接的用户
            with self.client_map_lock:
                for user, sock in list(self.client_map.items()):
                    if sock == ssock:
                        del self.client_map[user]
                        break
            logging.info(f"客户端断开连接: {client_address}")
            client_socket.close()

    def build_listen(self):
        # 生成SSL上下文
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain("SSL/tsetcn.crt", "SSL/tsetcn.pem")

        # 创建TCP socket，设置地址复用，绑定地址并监听
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind((self.host, self.port))
        server_socket.listen(100)
        logging.info(f"服务器启动，监听 {self.host}:{self.port}")

        # 循环等待并接受客户端连接
        while True:
            try:
                client_socket, client_address = server_socket.accept()
                client_thread = threading.Thread(target=self.handle_client,
                                                 args=(client_socket, client_address, context))
                client_thread.daemon = True
                client_thread.start()

            except Exception as e:
                logging.error(f"接受客户端连接时出错: {e}")


if __name__ == "__main__":
    server = Server()
    server.build_listen()


