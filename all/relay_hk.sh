#!/usr/bin/env bash
# ============================================================
# 🇭🇰 香港 NAT VPS —— VLESS-REALITY 中转鸡 (全系统通用版)
# ============================================================

set -euo pipefail

CONFIG="/etc/sing-box/config.json"
INFO="/root/relay_info.txt"

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
echo "      🇭🇰 Sing-box VLESS-REALITY 中转鸡一键部署"
echo "============================================================"
echo

# ------------------------------------------------------------
# 交互式参数输入
# ------------------------------------------------------------
read -rp "请输入【美国 RN 落地 IP】: " LAND_IP
read -rp "请输入【美国 RN 落地端口】: " LAND_PORT
read -rp "请输入【美国 RN 落地 UUID】: " LAND_UUID
read -rp "请输入【香港公网映射端口】: " HK_PORT

[[ -n "$LAND_IP" ]] || { error "美国 IP 不能为空"; exit 1; }
[[ "$LAND_PORT" =~ ^[0-9]+$ ]] || { error "美国端口格式不正确"; exit 1; }
[[ "$HK_PORT" =~ ^[0-9]+$ ]] || { error "香港端口格式不正确"; exit 1; }

# ------------------------------------------------------------
# 基础依赖与 Sing-box 官方二进制安装
# ------------------------------------------------------------
info "正在安装系统依赖..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl wget jq tar ca-certificates openssl
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget jq tar ca-certificates openssl
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl wget jq tar ca-certificates openssl
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl wget jq tar ca-certificates openssl
else
    error "未识别的包管理器"
    exit 1
fi

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
# 生成 REALITY 秘钥与配置
# ------------------------------------------------------------
HK_UUID="$(cat /proc/sys/kernel/random/uuid)"

# 动态生成 REALITY x25519 密钥对与 Short ID
KEY_PAIR="$(sing-box generate x25519 2>/dev/null)"
PRIVATE_KEY="$(echo "$KEY_PAIR" | grep -i "PrivateKey" | awk '{print $2}')"
PUBLIC_KEY="$(echo "$KEY_PAIR" | grep -i "PublicKey" | awk '{print $2}')"
SHORT_ID="$(sing-box generate rand 8 --hex 2>/dev/null || echo "1234567890abcdef")"
DEST_SNI="www.apple.com"

cat > "$CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "hk-in",
      "listen": "::",
      "listen_port": ${HK_PORT},
      "users": [
        {
          "uuid": "${HK_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DEST_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${DEST_SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "to-us",
      "server": "${LAND_IP}",
      "server_port": ${LAND_PORT},
      "uuid": "${LAND_UUID}",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "insecure": true
      }
    },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["hk-in"],
        "action": "route",
        "outbound": "to-us"
      }
    ],
    "final": "direct"
  }
}
EOF

info "检查配置文件语法..."
sing-box check -c "$CONFIG"

# ------------------------------------------------------------
# 服务托管与防火墙放行
# ------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box HK Relay Service
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

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
    ufw allow "${HK_PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --add-port="${HK_PORT}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "${HK_PORT}" -j ACCEPT || true
fi

# 获取香港外网 IP
PUBLIC_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
    PUBLIC_IP="$(curl -4 -fsSL --max-time 5 "$url" 2>/dev/null || true)"
    [[ -n "$PUBLIC_IP" ]] && break
done
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="YOUR_HK_PUBLIC_IP"

# 生成客户端订阅节点 (VLESS-REALITY)
CLIENT_URL="vless://${HK_UUID}@${PUBLIC_IP}:${HK_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#HK-REALITY-US-RN"

cat > "$INFO" <<EOF
============================================================
🇭🇰 香港 NAT VPS —— VLESS-REALITY 线路鸡部署成功
============================================================

客户端节点链接 (适用于 v2rayN / Sing-box / Shadowrocket / Clash Meta):

${CLIENT_URL}

============================================================
网络架构:
手机/电脑 (VLESS+REALITY) ➔ 香港 NAT VPS (VLESS+TLS) ➔ 美国落地 ➔ 目标网站
============================================================
EOF

echo
cat "$INFO"

echo
echo "============================================================"
echo "测试香港到美国落地的 TCP 端口连通性..."
echo "============================================================"

if command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/${LAND_IP}/${LAND_PORT}" 2>/dev/null \
        && info "香港 ➔ 美国落地端口 TCP 连通成功！" \
        || warn "香港 ➔ 美国落地端口无法连接，请检查美国机防火墙或端口映射！"
fi
