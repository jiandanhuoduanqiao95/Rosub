#!/usr/bin/env bash
# Rosub 服务端发行包制作
# 用法: scripts/package_server_release.sh [版本号]    （默认 1.0.0）
# 原理: git archive 只收录白名单路径下的已跟踪文件——tests/、开发文档、
#       数据库、证书、__pycache__、客户端源码等天然不会进入发行包。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
OUT="dist/chatroom-server-v${VERSION}.tar.gz"

# ── 打包前体检 ────────────────────────────────────────────────
if grep -q 'admin_secret: ""' config.yaml; then
  echo "[ok] config.yaml admin_secret 为空（密钥仅经环境变量注入）"
else
  echo "[拒绝打包] config.yaml 的 security.admin_secret 非空——发行包严禁携带密钥"
  exit 1
fi
grep -q 'host: "0.0.0.0"' config.yaml ||
  echo "[提示] server.host 非 0.0.0.0：部署后外部无法访问，请在目标机修改"

# ── 白名单打包 ────────────────────────────────────────────────
WHITELIST=(
  server/ database.py config.py config.yaml protocol.py validation.py
  admin.py requirements.txt
  SSL/gen_cert.py SSL/SSL.py
  scripts/renew_cert.py scripts/setup_wizard.py
  backup/
  deploy/
  部署指南.md README.md
)
mkdir -p dist
rm -f "$OUT"
git archive HEAD --output="$OUT" -- "${WHITELIST[@]}"

# ── 内容核对：白名单必备 ──────────────────────────────────────
LISTING=$(tar -tzf "$OUT")
MISS=0
while IFS= read -r f; do
  grep -qx "$f" <<<"$LISTING" || { echo "[缺失] $f"; MISS=1; }
done <<'EOF'
server/server_main.py
database.py
config.py
config.yaml
protocol.py
validation.py
admin.py
requirements.txt
SSL/gen_cert.py
scripts/renew_cert.py
scripts/setup_wizard.py
backup/backup.py
backup/restore.py
deploy/chatroom.service
部署指南.md
EOF
[ "$MISS" -eq 0 ] || { echo "[失败] 白名单核对未通过"; exit 1; }

# ── 内容核对：黑名单禁入 ──────────────────────────────────────
FORBIDDEN='(^|/)(tests?/|__pycache__|\.venv|chatroom_flutter/)|\.db$|\.sqlite|\.pem$|\.crt$|\.key$|TESTING_GUIDE|AGENTS\.md'
if grep -Eq "$FORBIDDEN" <<<"$LISTING"; then
  echo "[拒绝] 发行包混入禁入内容："
  grep -E "$FORBIDDEN" <<<"$LISTING" | head -10
  exit 1
fi

# ── 产物信息 ─────────────────────────────────────────────────
N=$(grep -vc '/$' <<<"$LISTING")
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
echo "──────────────────────────────────────────────"
echo "发行包: $OUT"
echo "文件数: $N"
echo "SHA256: $SHA"
