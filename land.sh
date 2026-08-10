#!/usr/bin/env bash
# ============================================================
# 🇺🇸 美西 RN VPS —— Sing-box VLESS 落地鸡 (Alpine 专用版)
# ============================================================

set -euo pipefail

CONFIG="/etc/sing-box/config.json"
INFO="/root/land_info.txt"
PORT="${PORT:-443}"
SERVICE_FILE="/etc/init.d/sing-box"
CERT_DIR="/etc/sing-box/cert"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+] $*${NC}"; }
warn()  { echo -e "${YELLOW}[!] $*${NC}"; }
error() { echo -e "${RED}[-] $*${NC}"; }

[[ $EUID -eq 0 ]] || { error "请使用 root 权限运行"; exit 1; }

if ! command -v apk >/dev/null 2>&1; then
    error "本脚本仅适用于 Alpine Linux (未检测到 apk 命令)"
    exit 1
fi

# ------------------------------------------------------------
# 卸载功能
# ------------------------------------------------------------
uninstall() {
    echo
    echo "============================================================"
    echo "        🇺🇸 Sing-box 落地鸡卸载"
    echo "============================================================"
    echo

    if [[ -f "$SERVICE_FILE" ]]; then
        info "停止并禁用 sing-box 服务..."
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box default 2>/dev/null || true
        rm -f "$SERVICE_FILE"
    else
        warn "未找到 OpenRC 服务文件，跳过服务停用"
    fi

    if command -v iptables >/dev/null 2>&1; then
        info "移除防火墙放行规则 (端口 ${PORT})..."
        iptables -D INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
    fi

    info "删除 sing-box 二进制及配置文件..."
    rm -f /usr/bin/sing-box
    rm -rf /etc/sing-box
    rm -f "$INFO"

    info "卸载完成，系统已恢复干净状态。"
    exit 0
}

if [[ "${1:-}" == "--uninstall" || "${1:-}" == "uninstall" ]]; then
    uninstall
fi

echo
echo "============================================================"
echo "        🇺🇸 Sing-box VLESS 落地鸡一键部署 (Alpine 版)"
echo "============================================================"
echo

# ------------------------------------------------------------
# 基础依赖安装
# ------------------------------------------------------------
info "正在检查并安装系统依赖..."
apk add --no-cache curl wget jq tar ca-certificates openssl openrc

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
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
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
mv "/tmp/singbox-bin/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box" /usr/bin/sing-box
chmod +x /usr/bin/sing-box
rm -rf /tmp/singbox-bin

info "Sing-box 安装成功: $(sing-box version | head -n1)"

# ------------------------------------------------------------
# 证书与参数配置
# ------------------------------------------------------------
UUID="$(cat /proc/sys/kernel/random/uuid)"
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
# OpenRC 服务托管
# ------------------------------------------------------------
info "正在配置 OpenRC 服务..."
cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box VLESS landing service"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
EOF
chmod +x "$SERVICE_FILE"

rc-update add sing-box default
rc-service sing-box restart

# ------------------------------------------------------------
# 防火墙放行 (Alpine 默认多用 iptables，也可能未启用)
# ------------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT || true
    if command -v /etc/init.d/iptables >/dev/null 2>&1 || [[ -f /etc/init.d/iptables ]]; then
        /etc/init.d/iptables save >/dev/null 2>&1 || true
    fi
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
🇺🇸 美国 RN 落地鸡部署成功 (Alpine)
============================================================
LAND_IP=${PUBLIC_IP}
LAND_PORT=${PORT}
LAND_UUID=${UUID}
============================================================
请将上方三行信息复制保存，稍后在香港中转鸡部署时输入。

卸载本节点，请运行:
  bash $(basename "$0") --uninstall
============================================================
EOF

echo
cat "$INFO"
