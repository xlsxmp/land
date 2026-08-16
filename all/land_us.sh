#!/usr/bin/env bash
# ============================================================
# 🇺🇸 美西 RN VPS —— Sing-box VLESS 落地鸡 (全系统通用版)
# ============================================================

set -euo pipefail

CONFIG="/etc/sing-box/config.json"
INFO="/root/land_info.txt"
PORT="${PORT:-443}"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+] $*${NC}"; }
warn()  { echo -e "${YELLOW}[!] $*${NC}"; }
error() { echo -e "${RED}[-] $*${NC}"; }

[[ $EUID -eq 0 ]] || { error "请使用 root 权限运行"; exit 1; }

echo
echo "============================================================"
echo "        🇺🇸 Sing-box VLESS 落地鸡一键部署 (官方二进制版)"
echo "============================================================"
echo

# ------------------------------------------------------------
# 基础依赖安装 (兼容全系统)
# ------------------------------------------------------------
info "正在检查并安装系统依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl wget jq tar ca-certificates openssl
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget jq tar ca-certificates openssl
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget jq tar ca-certificates openssl
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl wget jq tar ca-certificates openssl
else
    error "未识别的包管理器，请手动安装: curl wget jq tar openssl"
    exit 1
fi

# ------------------------------------------------------------
# 下载并安装官方 Sing-box 二进制文件
# ------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    armv7l)  SB_ARCH="armv7" ;;
    *) error "不支持的架构: $ARCH"; exit 1 ;;
esac

info "获取 Sing-box 官方最新版本..."
LATEST_TAG=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name 2>/dev/null || echo "")
if [[ -z "$LATEST_TAG" ]]; then
    warn "无法连接 GitHub API，使用备用稳定版本 v1.11.0"
    LATEST_TAG="v1.11.0"
fi

VERSION="${LATEST_TAG#v}"
TARBALL="sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${TARBALL}"

info "正在下载 Sing-box (${LATEST_TAG})..."
mkdir -p /etc/sing-box /tmp/singbox-bin
curl -fsSL "$DOWNLOAD_URL" -o "/tmp/singbox-bin/${TARBALL}"
tar -zxvf "/tmp/singbox-bin/${TARBALL}" -C /tmp/singbox-bin/
mv /tmp/singbox-bin/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box /usr/bin/sing-box
chmod +x /usr/bin/sing-box
rm -rf /tmp/singbox-bin

info "Sing-box 安装成功: $(sing-box version | head -n1)"

# ------------------------------------------------------------
# 证书与参数配置
# ------------------------------------------------------------
UUID="$(cat /proc/sys/kernel/random/uuid)"
CERT_DIR="/etc/sing-box/cert"
mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
    -subj "/CN=www.microsoft.com" >/dev/null 2>&1

chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

cat > "$CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "land-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_DIR}/server.crt",
        "key_path": "${CERT_DIR}/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

info "检查配置文件语法..."
sing-box check -c "$CONFIG"

# ------------------------------------------------------------
# 服务托管与防火墙设置
# ------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c ${CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

# 自动兼容并放行防火墙
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --add-port="${PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT || true
fi

# 获取外网 IP
PUBLIC_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
    PUBLIC_IP="$(curl -4 -fsSL --max-time 5 "$url" 2>/dev/null || true)"
    [[ -n "$PUBLIC_IP" ]] && break
done
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="YOUR_US_SERVER_IP"

# 保存连接信息
cat > "$INFO" <<EOF
============================================================
🇺🇸 美国 RN 落地鸡部署成功
============================================================
LAND_IP=${PUBLIC_IP}
LAND_PORT=${PORT}
LAND_UUID=${UUID}
============================================================
请将上方三行信息复制保存，稍后在香港中转鸡部署时输入。
============================================================
EOF

echo
cat "$INFO"
