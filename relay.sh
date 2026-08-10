#!/usr/bin/env bash
# ============================================================
# 🇭🇰 香港 NAT VPS —— VLESS-REALITY 中转鸡 (Alpine LXC 专用版)
# ============================================================

set -euo pipefail

CONFIG="/etc/sing-box/config.json"
INFO="/root/relay_info.txt"
SERVICE_FILE="/etc/init.d/sing-box"

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
    echo "      🇭🇰 Sing-box 中转鸡卸载 (Alpine)"
    echo "============================================================"
    echo

    local hk_port=""
    if [[ -f "$CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        hk_port="$(jq -r '.inbounds[0].listen_port // empty' "$CONFIG" 2>/dev/null || true)"
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        info "停止并禁用 sing-box 服务..."
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box default 2>/dev/null || true
        rm -f "$SERVICE_FILE"
    else
        warn "未找到 OpenRC 服务文件，跳过服务停用"
    fi

    if [[ -n "$hk_port" ]] && command -v iptables >/dev/null 2>&1; then
        info "尝试移除防火墙放行规则 (端口 ${hk_port})..."
        iptables -D INPUT -p tcp --dport "${hk_port}" -j ACCEPT 2>/dev/null \
            || warn "iptables 规则移除失败或本容器无网络管理权限，可忽略"
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
echo "      🇭🇰 Sing-box VLESS-REALITY 中转鸡一键部署 (Alpine LXC)"
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
[[ "$LAND_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || { error "美国 UUID 格式不正确"; exit 1; }

# ------------------------------------------------------------
# 基础依赖安装
# ------------------------------------------------------------
info "正在安装系统依赖..."
apk add --no-cache curl wget jq tar ca-certificates openssl openrc

# 官方 sing-box 二进制为 glibc 动态链接，Alpine 默认 musl libc 无法直接执行，
# 需要安装 gcompat 提供 glibc 兼容层
info "正在安装 glibc 兼容层 (gcompat)..."
apk add --no-cache gcompat

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

# 存储只有 1GB，下载解压完必须清理干净，避免占满容器磁盘
info "正在下载 Sing-box (${LATEST_TAG})..."
mkdir -p /etc/sing-box /tmp/singbox-bin
curl -fsSL "$DOWNLOAD_URL" -o "/tmp/singbox-bin/${TARBALL}"
tar -zxf "/tmp/singbox-bin/${TARBALL}" -C /tmp/singbox-bin/
mv "/tmp/singbox-bin/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box" /usr/bin/sing-box
chmod +x /usr/bin/sing-box
rm -rf /tmp/singbox-bin

if ! /usr/bin/sing-box version >/dev/null 2>&1; then
    error "sing-box 二进制无法执行，请确认 gcompat 是否安装成功 (apk info gcompat)"
    exit 1
fi
info "Sing-box 安装成功: $(sing-box version | head -n1)"

# ------------------------------------------------------------
# 生成 REALITY 秘钥与配置
# ------------------------------------------------------------
HK_UUID="$(cat /proc/sys/kernel/random/uuid)"

KEY_PAIR="$(sing-box generate reality-keypair 2>/dev/null)"
PRIVATE_KEY="$(echo "$KEY_PAIR" | grep -i "PrivateKey" | awk '{print $2}')"
PUBLIC_KEY="$(echo "$KEY_PAIR" | grep -i "PublicKey" | awk '{print $2}')"

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "REALITY 密钥生成失败，请检查 sing-box 版本输出格式"
    exit 1
fi

SHORT_ID="$(sing-box generate rand --hex 8 2>/dev/null || echo "1234567890abcdef")"
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
# OpenRC 服务托管
# ------------------------------------------------------------
info "正在配置 OpenRC 服务..."
cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box VLESS-REALITY relay service"
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
# 防火墙放行 (LXC 容器内常缺少 NET_ADMIN 权限，失败不阻断部署)
# ------------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
    if iptables -I INPUT -p tcp --dport "${HK_PORT}" -j ACCEPT 2>/dev/null; then
        info "已放行端口 ${HK_PORT}"
    else
        warn "iptables 规则添加失败（容器可能缺少 NET_ADMIN 权限），请在宿主机 / LXC 配置层面放行端口 ${HK_PORT}"
    fi
else
    warn "未检测到 iptables，请确认端口 ${HK_PORT} 已在宿主机层面放行"
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
🇭🇰 香港 NAT VPS (Alpine LXC) —— VLESS-REALITY 线路鸡部署成功
============================================================

客户端节点链接 (适用于 v2rayN / Sing-box / Shadowrocket / Clash Meta):

${CLIENT_URL}

============================================================
网络架构:
手机/电脑 (VLESS+REALITY) ➔ 香港 NAT VPS (VLESS+TLS) ➔ 美国落地 ➔ 目标网站

注意: 本容器为 LXC + Alpine 环境，若端口未通，请优先检查宿主机
NAT 转发 / 端口映射设置，而非仅检查容器内 iptables。

卸载本节点，请运行:
  bash $(basename "$0") --uninstall
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
