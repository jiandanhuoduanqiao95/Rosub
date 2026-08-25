# ============================================================
# 聊天室服务端 —— Docker 镜像（阶段 M5：P1-20）
# ============================================================
# 构建：docker build -f deploy/Dockerfile -t chatroom:latest .
# 运行：docker run -d --name chatroom -p 8090:8090 \
#         -e CHATROOM_ADMIN_SECRET='<你的密钥>' \
#         -v chatroom-data:/app/data chatroom:latest
# 数据卷 /app/data 持久化 users.db 与 file_store/（SSL 证书亦置于此）
# ============================================================

FROM python:3.12-slim

WORKDIR /app

# 依赖
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# 项目代码
COPY . .

# 数据目录（数据库 + 文件存储 + SSL 证书）
RUN mkdir -p /app/data
ENV CHATROOM_DATA_DIR=/app/data

# 默认服务端口
EXPOSE 8090

# 管理员密钥由运行环境注入（CHATROOM_ADMIN_SECRET）
CMD ["python", "server/server_main.py"]
